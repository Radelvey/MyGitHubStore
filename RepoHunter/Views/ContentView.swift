import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var search: SearchViewModel
    @EnvironmentObject private var downloader: Downloader

    @State private var sidebarSelection: SidebarItem? = .category(.all)
    @State private var selectedRepoID: Int?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selectedRepo: GHRepo? {
        search.repos.first { $0.id == selectedRepoID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            if sidebarSelection == .downloads {
                DownloadsListPlaceholder()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
            } else {
                RepoListView(selectedRepoID: $selectedRepoID)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)
            }
        } detail: {
            if sidebarSelection == .downloads {
                DownloadsView()
            } else if let repo = selectedRepo {
                RepoDetailView(repo: repo)
                    .id(repo.id)
            } else {
                EmptyDetailView()
            }
        }
        .onChange(of: sidebarSelection) { _, newValue in
            if case let .category(c) = newValue, c != search.category {
                search.category = c
                selectedRepoID = nil
                search.search()
            }
        }
        .task {
            if search.state == .idle { search.search() }
        }
    }
}

private struct DownloadsListPlaceholder: View {
    @EnvironmentObject private var downloader: Downloader

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(downloader.items.count) 条下载记录")
                .font(.headline)
            Text("\(downloader.activeCount) 个进行中")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyDetailView: View {
    @EnvironmentObject private var search: SearchViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("选择一个应用查看详情")
                .font(.title3)
            Text("当前系统：\(search.system.summary)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("RepoHunter 会自动为你的 Mac 挑选最合适的安装包")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
