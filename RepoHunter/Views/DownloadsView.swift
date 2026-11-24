import SwiftUI
import AppKit

struct DownloadsView: View {
    @EnvironmentObject private var downloader: Downloader

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载").font(.title2.weight(.semibold))
                    Text("保存到：\(downloader.destination.path)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(downloader.destination)
                } label: { Label("打开下载文件夹", systemImage: "folder") }
                Button(role: .destructive) {
                    downloader.clearFinished()
                } label: { Label("清除已结束记录", systemImage: "trash") }
                .disabled(!downloader.items.contains { !($0.isActive || $0.state == .paused) })
            }
            .padding(16)
            Divider()

            if downloader.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 44, weight: .thin)).foregroundStyle(.tertiary)
                    Text("还没有下载记录").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(downloader.items) { item in
                        DownloadRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("下载")
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @EnvironmentObject private var downloader: Downloader

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.assetName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(item.repoFullName)\(item.version.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)

                switch item.state {
                case .downloading, .queued, .paused:
                    ProgressView(value: item.progress)
                    HStack {
                        Text("\(Fmt.bytes(item.bytesReceived)) / \(Fmt.bytes(max(item.totalBytes, item.expectedSize)))")
                        Spacer()
                        if item.state == .downloading { Text(Fmt.speed(item.speed)) }
                        else { Text(item.state.title) }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .completed:
                    Text("\(item.state.title) · \(Fmt.bytes(item.totalBytes)) · \(Fmt.relativeDate(item.finishedAt))" +
                         (item.fileExists ? "" : " · 文件已被移动或删除"))
                        .font(.caption).foregroundStyle(item.fileExists ? Color.secondary : Color.orange)
                case .failed:
                    Text(item.errorMessage ?? "下载失败").font(.caption).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text("已取消").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 6)
        .contextMenu {
            if item.state == .completed, item.fileExists {
                Button("在 Finder 中显示") { downloader.revealInFinder(item.id) }
                Button("打开") { downloader.open(item.id) }
                Divider()
                Button("移到废纸篓并删除记录", role: .destructive) { downloader.remove(item.id, deleteFile: true) }
            }
            Button("删除记录", role: .destructive) { downloader.remove(item.id) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .downloading, .queued:
            HStack {
                Button { downloader.pause(item.id) } label: { Image(systemName: "pause.fill") }.help("暂停")
                Button { downloader.cancel(item.id) } label: { Image(systemName: "xmark") }.help("取消")
            }
            .buttonStyle(.borderless)
        case .paused:
            HStack {
                Button("继续") { downloader.resume(item.id) }
                Button { downloader.cancel(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("取消")
            }
        case .completed:
            HStack {
                Button { downloader.revealInFinder(item.id) } label: { Image(systemName: "folder") }
                    .help("在 Finder 中显示").disabled(!item.fileExists)
                Button {
                    if item.isDMG, let u = item.localURL { downloader.mountDMG(at: u) } else { downloader.open(item.id) }
                } label: { Image(systemName: item.isDMG ? "externaldrive.badge.plus" : "arrow.up.forward.app") }
                    .help(item.isDMG ? "挂载 DMG" : "打开").disabled(!item.fileExists)
                Button { downloader.remove(item.id) } label: { Image(systemName: "trash") }
                    .help("删除记录")
            }
            .buttonStyle(.borderless)
        case .failed, .cancelled:
            HStack {
                Button("重试") { downloader.resume(item.id) }
                Button { downloader.remove(item.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("删除记录")
            }
        }
    }

    private var icon: String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        case .paused: return "pause.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .paused: return .orange
        default: return .accentColor
        }
    }
}
