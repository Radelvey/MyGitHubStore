import SwiftUI

struct RepoListView: View {
    @EnvironmentObject private var search: SearchViewModel
    @Binding var selectedRepoID: Int?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if let msg = search.rateLimitMessage {
                Banner(message: msg, onDismiss: { search.dismissRateLimitBanner() })
                    .padding(8)
            }
            if search.isOffline {
                Banner(message: "当前显示的是本地缓存内容（离线模式）。",
                       systemImage: "externaldrive.fill", tint: .blue,
                       action: ("重新加载", { search.search() }))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            content
        }
        .navigationTitle(search.category.title)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        search.state == .loaded ? "共 \(Fmt.count(search.totalCount)) 个结果" : ""
    }

    // MARK: Filters

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用名称或关键词…", text: $search.query)
                    .textFieldStyle(.plain)
                    .onSubmit { search.search() }
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                        search.search()
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            HStack(spacing: 8) {
                Picker("排序", selection: $search.sort) {
                    ForEach(SearchSort.allCases) { Text($0.title).tag($0) }
                }
                Picker("语言", selection: $search.language) {
                    ForEach(LanguageFilter.allCases) { Text($0.title).tag($0) }
                }
                Picker("Stars", selection: $search.minStars) {
                    ForEach(StarFilter.allCases) { Text($0.title).tag($0) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(10)
        .onChange(of: search.sort) { _, _ in search.search() }
        .onChange(of: search.language) { _, _ in search.search() }
        .onChange(of: search.minStars) { _, _ in search.search() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch search.state {
        case .idle, .loading:
            if search.repos.isEmpty {
                ProgressView("正在搜索…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        case let .failed(message):
            ErrorStateView(message: message, retry: { search.retry() })
        case .loaded:
            if search.repos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("没有找到匹配的应用").foregroundStyle(.secondary)
                    Text("试试放宽语言或 Stars 限制").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(selection: $selectedRepoID) {
            ForEach(search.repos) { repo in
                RepoRow(repo: repo, state: search.releaseState(for: repo))
                    .tag(repo.id)
                    .onAppear { search.loadMoreIfNeeded(current: repo) }
            }
            if search.isLoadingMore {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if search.state == .loading {
                ProgressView().controlSize(.small).padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 6)
            }
        }
    }
}

struct RepoRow: View {
    let repo: GHRepo
    let state: ReleaseState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAvatar(url: repo.avatarURL, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.headline).lineLimit(1)
                    Text(repo.owner.login).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Label(Fmt.count(repo.stargazersCount), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                    if let lang = repo.language {
                        Text(lang).foregroundStyle(.secondary)
                    }
                    Text(Fmt.relativeDate(repo.pushedAt ?? repo.updatedAt)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    releaseBadge
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var releaseBadge: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.mini)
        case .none:
            Pill(text: "仅源码", tint: .gray)
        case let .loaded(version, pre, hasMac):
            HStack(spacing: 4) {
                if hasMac { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                Pill(text: version, tint: pre ? .orange : .blue)
            }
        case .failed:
            EmptyView()
        }
    }
}
