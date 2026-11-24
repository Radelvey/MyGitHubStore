# RepoHunter

在 GitHub 上搜索开源 macOS 应用，**按你的 Mac（Apple Silicon / Intel、macOS 版本）自动推荐安装包**，也可手动选择任意文件下载。纯 Swift / SwiftUI，无第三方依赖。

## 运行

1. 用 Xcode 15+ 打开 `RepoHunter.xcodeproj`
2. Target → Signing & Capabilities：选择你的 Team（或保持 *Sign to Run Locally*）
3. `⌘R` 运行（最低系统 macOS 14）

> 本机没有 Swift 编译器可用，工程文件由脚本生成；如首次编译遇到个别报错，把错误贴给我即可快速修正。

## 功能

| 模块 | 说明 |
| --- | --- |
| 搜索 | GitHub Search API（关键词 / 分类 topic / 语言 / 最低 Stars / 排序），滚动分页，自动过滤 fork 与归档仓库 |
| 列表 | 名称、描述、Stars、最近更新、最新 Release 版本、"仅源码"标记、✓ 表示有适配你系统的安装包 |
| 详情 | 三个页签：**下载** / **README**（Markdown 渲染） / **更新日志**；可切换历史版本、是否包含预发布 |
| 智能推荐 | 对 Release assets 打分，选出最佳并写明理由（如"匹配 Apple Silicon"） |
| 手动选择 | 列出所有文件（名称、大小、下载次数、判定理由）；被判定不适用的文件折叠在"其他文件"中，仍可下载 |
| 下载管理 | 进度、速度、暂停 / 继续 / 取消 / 重试；历史记录；完成后可在 Finder 显示、打开、DMG 自动挂载 |
| 设置 | GitHub Token（存 Keychain，可验证）、下载目录、自动挂载 DMG、缓存管理（⌘,） |
| 离线 | 搜索结果、Release、README、头像落盘缓存；网络失败或被限流时回退到缓存并提示 |
| 无 Release | 提示"仅源码"，提供 GitHub 链接、源码 ZIP 和 `brew install --cask` 命令（可复制） |

## 推荐规则（`Services/AssetPicker.swift`）

打分制，最高分且分数 ≥ 25 的兼容文件为"推荐"：

- **排除**：`.exe .msi .deb .rpm .AppImage .apk .tar.gz .7z …`、校验/签名文件、源码包、文件名含 windows/linux 等且无 mac 关键字
- **格式**：dmg +50 › pkg +40 › zip +30
- **mac 关键字**（macos / darwin / osx）+20
- **架构**：与本机一致 +35；universal +28；不匹配 −25（Intel 机器上的 arm64 包 −60）；未标注架构 +8
- **系统版本**：文件名含 `macos12` 之类且高于当前系统 −40
- 惩罚 debug / nightly / 过小文件

新增规则只需在 `score(_:)` 里加一段加减分即可。

## 目录结构

```
RepoHunter/
├─ Models/        GitHub API 模型、下载模型、筛选/状态枚举
├─ Services/      GitHubAPI · AssetPicker · Downloader · DiskCache · KeychainStore
│                 SystemInfo · MarkdownRenderer · Formatters
├─ ViewModels/    SearchViewModel · DetailViewModel · SettingsStore
└─ Views/         ContentView(三栏) · Sidebar · RepoList · RepoDetail
                  Downloads · Settings · MarkdownWebView · Components
```

## 关于沙盒与安全

- 默认**关闭沙盒**（`RepoHunter.entitlements`），以便自由写入下载目录并调用 `hdiutil` 挂载 DMG。若要上架/沙盒化：开启 `app-sandbox`，保留 `network.client` 与 `files.*`，并把 DMG 挂载改为 `NSWorkspace.open`。
- README 在**禁用 JavaScript** 的 WKWebView 中渲染，原始 HTML 会剔除 script / iframe / 事件属性，链接一律交给默认浏览器打开。
- 下载的第三方应用可能未签名/未公证；下载页有提示，首次打开被拦截请在"系统设置 › 隐私与安全性"中确认。
- 第一版只下载，不自动安装到 /Applications。

## GitHub API 限流

未登录每小时 60 次（本应用会为列表里每个仓库查询一次最新 Release，消耗较快）。在设置里填入 Personal Access Token（无需任何权限）后提升到 5000 次/小时。限流时会显示重置时间并回退到缓存。
