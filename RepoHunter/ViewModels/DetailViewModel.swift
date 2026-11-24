import Foundation
import SwiftUI

@MainActor
final class DetailViewModel: ObservableObject {
    let repo: GHRepo
    let system: SystemInfo

    @Published private(set) var readme: String?
    @Published private(set) var readmeState: LoadState = .idle
    @Published private(set) var releases: [GHRelease] = []
    @Published private(set) var releasesState: LoadState = .idle
    @Published private(set) var isOffline = false
    @Published var selectedReleaseID: Int?
    @Published var showPrereleases = false

    private let api = GitHubAPI.shared
    private let cache = DiskCache.shared

    init(repo: GHRepo, system: SystemInfo) {
        self.repo = repo
        self.system = system
    }

    // MARK: Derived

    var visibleReleases: [GHRelease] {
        showPrereleases ? releases : releases.filter { !$0.prerelease }
    }

    var hasPrereleases: Bool { releases.contains { $0.prerelease } }

    var selectedRelease: GHRelease? {
        if let id = selectedReleaseID, let r = visibleReleases.first(where: { $0.id == id }) { return r }
        return visibleReleases.first ?? releases.first
    }

    var recommendation: AssetRecommendation? {
        guard let r = selectedRelease else { return nil }
        return AssetPicker(system: system).recommend(from: r.assets)
    }

    // MARK: Loading

    func load() async {
        async let a: Void = loadReadme()
        async let b: Void = loadReleases()
        _ = await (a, b)
    }

    func reload() async {
        readmeState = .idle
        releasesState = .idle
        await load()
    }

    private func loadReadme() async {
        let key = "readme|\(repo.fullName)"
        readmeState = .loading
        do {
            let text = try await api.readme(fullName: repo.fullName)
            readme = text
            cache.store(Box(value: text), key: key)
            readmeState = .loaded
        } catch is CancellationError {
            return
        } catch {
            if let cached = cache.load(Box<String>.self, key: key) {
                readme = cached.value
                isOffline = true
                readmeState = .loaded
            } else {
                readmeState = .failed(Self.message(error))
            }
        }
    }

    private func loadReleases() async {
        let key = "releases|\(repo.fullName)"
        releasesState = .loading
        do {
            let list = try await api.releases(fullName: repo.fullName)
            releases = list
            cache.store(list, key: key)
            releasesState = .loaded
            if let first = visibleReleases.first ?? list.first { selectedReleaseID = first.id }
        } catch is CancellationError {
            return
        } catch {
            if let cached = cache.load([GHRelease].self, key: key) {
                releases = cached
                isOffline = true
                releasesState = .loaded
                if let first = visibleReleases.first ?? cached.first { selectedReleaseID = first.id }
            } else {
                releasesState = .failed(Self.message(error))
            }
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
