import Foundation
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    // Inputs
    @Published var query: String = ""
    @Published var category: RepoCategory = .all
    @Published var sort: SearchSort = .stars
    @Published var language: LanguageFilter = .any
    @Published var minStars: StarFilter = .any

    // Outputs
    @Published private(set) var repos: [GHRepo] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isOffline = false
    @Published private(set) var rateLimitMessage: String?
    @Published private(set) var releaseStates: [Int: ReleaseState] = [:]

    private var page = 1
    private let perPage = 30
    private var searchTask: Task<Void, Never>?
    private let api = GitHubAPI.shared
    private let cache = DiskCache.shared
    let system = SystemInfo.detect()

    var canLoadMore: Bool { !isOffline && repos.count < min(totalCount, 1000) && state == .loaded && !isLoadingMore }

    // MARK: Query building

    private var fullQuery: String {
        var parts: [String] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        parts.append(category.extraQuery)
        if let lang = language.qualifier { parts.append(lang) }
        if minStars != .any { parts.append("stars:>=\(minStars.rawValue)") }
        parts.append("archived:false")
        parts.append("fork:false")
        return parts.joined(separator: " ")
    }

    private var cacheKey: String { "search|\(fullQuery)|\(sort.rawValue)" }

    // MARK: Actions

    func search() {
        searchTask?.cancel()
        page = 1
        searchTask = Task { await runSearch(reset: true) }
    }

    func loadMoreIfNeeded(current repo: GHRepo) {
        guard canLoadMore, let last = repos.last, last.id == repo.id else { return }
        searchTask = Task { await runSearch(reset: false) }
    }

    func retry() { search() }

    private func runSearch(reset: Bool) async {
        if reset {
            state = .loading
            rateLimitMessage = nil
        } else {
            isLoadingMore = true
        }
        let nextPage = reset ? 1 : page + 1
        do {
            let resp = try await api.searchRepos(query: fullQuery, sort: sort, page: nextPage, perPage: perPage)
            if Task.isCancelled { return }
            isOffline = false
            totalCount = resp.totalCount
            if reset {
                repos = resp.items
                cache.store(resp, key: cacheKey)
            } else {
                let existing = Set(repos.map(\.id))
                repos += resp.items.filter { !existing.contains($0.id) }
            }
            page = nextPage
            state = .loaded
            isLoadingMore = false
            prefetchReleases(for: resp.items)
        } catch is CancellationError {
            isLoadingMore = false
        } catch {
            if Task.isCancelled { return }
            isLoadingMore = false
            handleSearchFailure(error, reset: reset)
        }
    }

    private func handleSearchFailure(_ error: Error, reset: Bool) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let gh = error as? GitHubError, gh.isRateLimit { rateLimitMessage = message }

        guard reset else {
            // A failed "load more" keeps the existing list.
            state = .loaded
            rateLimitMessage = rateLimitMessage ?? message
            return
        }
        // Fall back to cached results (offline browsing).
        if let cached = cache.load(GHSearchResponse.self, key: cacheKey) {
            repos = cached.items
            totalCount = cached.totalCount
            isOffline = true
            state = .loaded
            if rateLimitMessage == nil { rateLimitMessage = message }
            prefetchReleases(for: cached.items)
        } else {
            repos = []
            totalCount = 0
            isOffline = false
            state = .failed(message)
        }
    }

    // MARK: Release badges for the list

    func releaseState(for repo: GHRepo) -> ReleaseState {
        releaseStates[repo.id] ?? .loading
    }

    private func prefetchReleases(for items: [GHRepo]) {
        for repo in items where releaseStates[repo.id] == nil || releaseStates[repo.id] == .failed {
            // Cached first.
            let key = "latest|\(repo.fullName)"
            if let boxed = cache.load(Box<GHRelease>.self, key: key), (cache.age(key: key) ?? .infinity) < 3600 {
                releaseStates[repo.id] = summarize(boxed.value)
                continue
            }
            if isOffline {
                if let boxed = cache.load(Box<GHRelease>.self, key: key) {
                    releaseStates[repo.id] = summarize(boxed.value)
                } else {
                    releaseStates[repo.id] = .failed
                }
                continue
            }
            releaseStates[repo.id] = .loading
        }
        // Throttle: at most 4 concurrent lookups to be kind to the rate limit.
        let pending = items.filter { releaseStates[$0.id] == .loading }
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                var running = 0
                func addNext(_ g: inout TaskGroup<Void>) {
                    guard let repo = iterator.next() else { return }
                    running += 1
                    g.addTask { [weak self] in await self?.fetchLatest(repo) }
                }
                for _ in 0..<4 { addNext(&group) }
                while running > 0 {
                    await group.next()
                    running -= 1
                    if Task.isCancelled { group.cancelAll(); break }
                    addNext(&group)
                }
            }
        }
    }

    private func fetchLatest(_ repo: GHRepo) async {
        let key = "latest|\(repo.fullName)"
        do {
            let release = try await api.latestRelease(fullName: repo.fullName)
            cache.store(Box(value: release), key: key)
            releaseStates[repo.id] = summarize(release)
        } catch is CancellationError {
            // leave as loading
        } catch {
            if let gh = error as? GitHubError, gh.isRateLimit {
                rateLimitMessage = gh.errorDescription
            }
            releaseStates[repo.id] = .failed
        }
    }

    private func summarize(_ release: GHRelease?) -> ReleaseState {
        guard let release else { return .none }
        let picker = AssetPicker(system: system)
        let hasMac = picker.recommend(from: release.assets).best != nil
        return .loaded(version: release.tagName, prerelease: release.prerelease, hasMacAsset: hasMac)
    }

    func dismissRateLimitBanner() { rateLimitMessage = nil }
}
