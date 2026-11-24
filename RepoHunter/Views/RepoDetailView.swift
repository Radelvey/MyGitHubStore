import SwiftUI
import AppKit

private enum DetailTab: String, CaseIterable, Identifiable {
    case download = "下载"
    case readme = "README"
    case notes = "更新日志"
    var id: String { rawValue }
}

struct RepoDetailView: View {
    let repo: GHRepo

    @EnvironmentObject private var search: SearchViewModel
    @EnvironmentObject private var downloader: Downloader
    @StateObject private var vm: DetailViewModel
    @State private var tab: DetailTab = .download

    init(repo: GHRepo) {
        self.repo = repo
        _vm = StateObject(wrappedValue: DetailViewModel(repo: repo, system: SystemInfo.detect()))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.vertical, 10)
            Divider()
            Group {
                switch tab {
                case .download: DownloadTab(vm: vm)
                case .readme: readmeTab
                case .notes: notesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await vm.load() }
        .navigationTitle(repo.name)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await vm.reload() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .help("重新获取 Release 与 README")
                if let url = repo.htmlURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("在 GitHub 打开", systemImage: "safari") }
                        .help("在浏览器中打开仓库")
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAvatar(url: repo.avatarURL, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.fullName).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let d = repo.description, !d.isEmpty {
                    Text(d).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Label(Fmt.count(repo.stargazersCount), systemImage: "star.fill").foregroundStyle(.yellow)
                    Label(Fmt.count(repo.forksCount), systemImage: "tuningfork").foregroundStyle(.secondary)
                    if let l = repo.language { Label(l, systemImage: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary) }
                    if let lic = repo.license?.spdxId, lic != "NOASSERTION" { Label(lic, systemImage: "doc.text").foregroundStyle(.secondary) }
                    Label("更新于 \(Fmt.relativeDate(repo.pushedAt ?? repo.updatedAt))", systemImage: "clock").foregroundStyle(.secondary)
                }
                .font(.caption)
                if let topics = repo.topics, !topics.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) { ForEach(topics.prefix(12), id: \.self) { Pill(text: $0, tint: .accentColor) } }
                    }
                }
                if vm.isOffline {
                    Pill(text: "离线缓存", tint: .blue, systemImage: "externaldrive.fill")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: README / notes

    private var rawBase: URL? {
        URL(string: "https://raw.githubusercontent.com/\(repo.fullName)/\(repo.branch)/")
    }

    @ViewBuilder
    private var readmeTab: some View {
        switch vm.readmeState {
        case .idle, .loading:
            ProgressView("加载 README…")
        case let .failed(msg):
            ErrorStateView(message: msg, retry: { Task { await vm.reload() } })
        case .loaded:
            if let text = vm.readme, !text.isEmpty {
                MarkdownWebView(markdown: text, baseURL: rawBase)
                    .padding(.horizontal, 12)
            } else {
                Text("该仓库没有 README").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notesTab: some View {
        switch vm.releasesState {
        case .idle, .loading:
            ProgressView("加载 Release…")
        case let .failed(msg):
            ErrorStateView(message: msg, retry: { Task { await vm.reload() } })
        case .loaded:
            if let release = vm.selectedRelease {
                VStack(spacing: 0) {
                    HStack {
                        Text(release.title).font(.headline)
                        Pill(text: release.tagName, tint: .blue)
                        if release.prerelease { Pill(text: "预发布", tint: .orange) }
                        Spacer()
                        Text(Fmt.date(release.publishedAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownWebView(markdown: body, baseURL: rawBase).padding(.horizontal, 12)
                    } else {
                        Text("此版本没有更新说明").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                Text("该仓库没有发布版本").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Download tab

private struct DownloadTab: View {
    @ObservedObject var vm: DetailViewModel
    @EnvironmentObject private var downloader: Downloader

    var body: some View {
        switch vm.releasesState {
        case .idle, .loading:
            ProgressView("加载 Release…")
        case let .failed(msg):
            ErrorStateView(message: msg, retry: { Task { await vm.reload() } })
        case .loaded:
            if vm.releases.isEmpty {
                NoReleaseView(repo: vm.repo)
            } else {
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                releasePicker
                if let rec = vm.recommendation, let release = vm.selectedRelease {
                    if let best = rec.best {
                        RecommendedCard(scored: best, repo: vm.repo.fullName, version: release.tagName, system: vm.system)
                    } else {
                        Banner(message: rec.all.isEmpty
                               ? "此版本没有附带可下载的文件。"
                               : "没有找到适合 \(vm.system.summary) 的安装包，可在下方手动选择。")
                    }

                    if !rec.compatible.isEmpty {
                        Text("所有可用文件（\(rec.compatible.count)）").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(rec.compatible) { s in
                                AssetRow(scored: s, repo: vm.repo.fullName, version: release.tagName,
                                         isBest: s.id == rec.best?.id)
                                if s.id != rec.compatible.last?.id { Divider() }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
                    }

                    if !rec.others.isEmpty {
                        DisclosureGroup("其他文件（\(rec.others.count)，已判定不适用于 macOS）") {
                            VStack(spacing: 0) {
                                ForEach(rec.others) { s in
                                    AssetRow(scored: s, repo: vm.repo.fullName, version: release.tagName, isBest: false)
                                    if s.id != rec.others.last?.id { Divider() }
                                }
                            }
                            .padding(.top, 6)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                securityNote
            }
            .padding(20)
        }
    }

    private var releasePicker: some View {
        HStack {
            Text("版本").font(.headline)
            Picker("", selection: Binding(
                get: { vm.selectedRelease?.id ?? 0 },
                set: { vm.selectedReleaseID = $0 }
            )) {
                ForEach(vm.visibleReleases) { r in
                    Text(r.tagName + (r.prerelease ? "（预发布）" : "")).tag(r.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            if vm.hasPrereleases {
                Toggle("包含预发布", isOn: $vm.showPrereleases)
                    .toggleStyle(.checkbox)
                    .onChange(of: vm.showPrereleases) { _, _ in
                        if let first = vm.visibleReleases.first, !vm.visibleReleases.contains(where: { $0.id == vm.selectedReleaseID }) {
                            vm.selectedReleaseID = first.id
                        }
                    }
            }
            Spacer()
            if let r = vm.selectedRelease {
                Text("发布于 \(Fmt.date(r.publishedAt))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var securityNote: some View {
        Label("下载的应用来自第三方，可能未经签名或公证。首次打开如被 Gatekeeper 拦截，请先确认来源可信，再到「系统设置 › 隐私与安全性」中选择「仍要打开」。",
              systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }
}

// MARK: - No release

private struct NoReleaseView: View {
    let repo: GHRepo

    private var brewCommand: String { "brew install --cask \(repo.name.lowercased())" }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 40, weight: .thin)).foregroundStyle(.tertiary)
            Text("该仓库没有发布 Release").font(.title3)
            Text("作者只提供了源码，需要自行用 Xcode 编译。").foregroundStyle(.secondary)
            HStack {
                if let url = repo.htmlURL {
                    Button("在 GitHub 查看") { NSWorkspace.shared.open(url) }
                }
                if repo.sourceZipURL != nil {
                    Button("在浏览器下载源码 ZIP") {
                        if let u = repo.sourceZipURL { NSWorkspace.shared.open(u) }
                    }
                }
            }
            VStack(spacing: 4) {
                Text("如果它收录在 Homebrew，也可以尝试：").font(.caption).foregroundStyle(.tertiary)
                HStack {
                    Text(brewCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(brewCommand, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("复制命令")
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recommended card

private struct RecommendedCard: View {
    let scored: ScoredAsset
    let repo: String
    let version: String
    let system: SystemInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.white)
                Text("为你的 Mac 推荐").font(.caption.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Text(system.summary).font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.accentColor)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon(for: scored.asset.fileExtension))
                    .font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scored.asset.name).font(.headline).textSelection(.enabled)
                    Text("\(scored.asset.sizeText) · \(Fmt.count(scored.asset.downloadCount)) 次下载")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("推荐理由：\(scored.reasonText)").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                DownloadButton(asset: scored.asset, repo: repo, version: version, prominent: true)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.4)))
    }

    private func icon(for ext: String) -> String {
        switch ext {
        case "dmg": return "externaldrive.fill"
        case "pkg": return "shippingbox.fill"
        case "zip": return "doc.zipper"
        default: return "app.gift.fill"
        }
    }
}

// MARK: - Asset row

private struct AssetRow: View {
    let scored: ScoredAsset
    let repo: String
    let version: String
    let isBest: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(scored.asset.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if isBest { Pill(text: "推荐", tint: .green, systemImage: "sparkles") }
                }
                HStack(spacing: 8) {
                    Text(scored.asset.sizeText)
                    Text("\(Fmt.count(scored.asset.downloadCount)) 次下载")
                    Text(scored.reasonText).foregroundStyle(scored.isCompatible ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            DownloadButton(asset: scored.asset, repo: repo, version: version, prominent: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Download button

struct DownloadButton: View {
    let asset: GHAsset
    let repo: String
    let version: String
    var prominent: Bool

    @EnvironmentObject private var downloader: Downloader

    private var item: DownloadItem? { downloader.latest(repo: repo, asset: asset.name) }

    var body: some View {
        Group {
            if let item, item.state == .downloading || item.state == .queued {
                HStack(spacing: 8) {
                    ProgressView(value: item.progress).frame(width: 90)
                    Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Button { downloader.pause(item.id) } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.borderless).help("暂停")
                    Button { downloader.cancel(item.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("取消")
                }
            } else if let item, item.state == .paused {
                HStack(spacing: 8) {
                    Text("已暂停 \(Int(item.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                    Button("继续") { downloader.resume(item.id) }
                }
            } else if let item, item.state == .completed, item.fileExists {
                HStack(spacing: 6) {
                    Button { downloader.revealInFinder(item.id) } label: { Label("显示", systemImage: "folder") }
                    Button {
                        if item.isDMG, let u = item.localURL { downloader.mountDMG(at: u) } else { downloader.open(item.id) }
                    } label: { Label("打开", systemImage: "arrow.up.forward.app") }
                }
                .controlSize(prominent ? .regular : .small)
            } else {
                downloadButton
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if prominent {
            Button { start() } label: { Label("下载", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            Button { start() } label: { Label("下载", systemImage: "arrow.down.circle") }
                .controlSize(.small)
        }
    }

    private func start() { downloader.start(asset: asset, repo: repo, version: version) }
}
