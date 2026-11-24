import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject private var search: SearchViewModel
    @EnvironmentObject private var downloader: Downloader

    var body: some View {
        List(selection: $selection) {
            Section("发现") {
                ForEach(RepoCategory.allCases) { cat in
                    Label(cat.title, systemImage: cat.symbol)
                        .tag(SidebarItem.category(cat))
                }
            }
            Section("管理") {
                HStack {
                    Label("下载", systemImage: "arrow.down.circle")
                    Spacer()
                    if downloader.activeCount > 0 {
                        Text("\(downloader.activeCount)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                }
                .tag(SidebarItem.downloads)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Label(search.system.archTitle, systemImage: "cpu")
                Label("macOS \(search.system.osVersionString)", systemImage: "desktopcomputer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
        }
    }
}
