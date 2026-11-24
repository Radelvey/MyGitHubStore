import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloader: Downloader

    @AppStorage("autoMountDMG") private var autoMountDMG = true
    @AppStorage("autoRevealAfterDownload") private var autoReveal = false

    @State private var tokenInput = ""
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section {
                if settings.hasToken {
                    LabeledContent("当前 Token") {
                        HStack {
                            Text(settings.maskedToken).font(.system(.body, design: .monospaced))
                            Button("移除", role: .destructive) { settings.removeToken() }
                        }
                    }
                } else {
                    SecureField("ghp_… 或 github_pat_…", text: $tokenInput)
                    HStack {
                        Button("验证并保存") {
                            let t = tokenInput
                            Task { await settings.saveToken(t); if settings.hasToken { tokenInput = "" } }
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || settings.isVerifying)
                        if settings.isVerifying { ProgressView().controlSize(.small) }
                    }
                }
                if let status = settings.tokenStatus {
                    Text(status).font(.caption)
                        .foregroundStyle(status.hasPrefix("✗") ? Color.red : Color.secondary)
                }
                Text("Token 仅保存在系统钥匙串中，用于提高 GitHub API 额度（每小时 60 → 5000 次）。无需勾选任何权限（公开仓库只读即可）。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("在 GitHub 创建 Token", destination: URL(string: "https://github.com/settings/tokens")!)
                    .font(.caption)
            } header: { Text("GitHub Token") }

            Section {
                LabeledContent("保存位置") {
                    HStack {
                        Text(downloader.destination.path)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("选择…") { chooseFolder() }
                    }
                }
                Toggle("下载完成后自动挂载 DMG", isOn: $autoMountDMG)
                Toggle("下载完成后在 Finder 中显示", isOn: $autoReveal)
            } header: { Text("下载") }

            Section {
                LabeledContent("缓存大小", value: Fmt.bytes(cacheSize))
                Button("清除缓存") {
                    DiskCache.shared.clear()
                    cacheSize = DiskCache.shared.sizeOnDisk()
                }
                Text("缓存包含搜索结果、Release、README 与头像，用于离线查看。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("缓存") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
        .onAppear { cacheSize = DiskCache.shared.sizeOnDisk() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloader.destination
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            downloader.destination = url
        }
    }
}
