import Foundation

/// Result of scoring one release asset against the current Mac.
struct ScoredAsset: Identifiable, Hashable {
    let asset: GHAsset
    let score: Int
    let reasons: [String]
    /// False for assets that cannot run on macOS at all (Windows, Linux, source, checksums...).
    let isCompatible: Bool

    var id: Int { asset.id }
    var reasonText: String { reasons.joined(separator: "，") }
}

struct AssetRecommendation {
    let all: [ScoredAsset]          // sorted: compatible first, by score desc
    let best: ScoredAsset?          // nil when nothing suitable

    var compatible: [ScoredAsset] { all.filter { $0.isCompatible } }
    var others: [ScoredAsset] { all.filter { !$0.isCompatible } }
}

/// Score-based asset picker. Add rules by appending to `rules` – each rule returns a delta + reason.
struct AssetPicker {
    let system: SystemInfo

    // Tokens are matched on word boundaries inside the lower-cased file name.
    private static let armTokens = ["arm64", "aarch64", "apple-silicon", "applesilicon", "apple_silicon", "silicon", "m1", "arm"]
    private static let intelTokens = ["x86_64", "x86-64", "x64", "amd64", "intel", "i386", "x86"]
    private static let universalTokens = ["universal", "universal2", "fat"]
    private static let macTokens = ["macos", "mac", "osx", "darwin", "apple"]

    private static let foreignExts: Set<String> = [
        "exe", "msi", "msix", "appx", "deb", "rpm", "appimage", "snap", "flatpak", "apk", "aab", "ipa",
        "tar.gz", "tar.xz", "tar.bz2", "tar.zst", "tgz", "7z", "rar", "whl", "jar", "nupkg", "gem"
    ]
    private static let metaExts: Set<String> = [
        "sha256", "sha512", "sha1", "md5", "sig", "asc", "pem", "sbom", "json", "jsonl", "intoto.jsonl",
        "txt", "yml", "yaml", "blockmap", "minisig", "sum", "cdx", "spdx", "pdf", "md"
    ]
    private static let foreignNameTokens = ["windows", "win32", "win64", "win", "linux", "ubuntu", "debian", "android", "ios", "freebsd", "musl"]

    func recommend(from assets: [GHAsset]) -> AssetRecommendation {
        let scored = assets.map(score).sorted {
            if $0.isCompatible != $1.isCompatible { return $0.isCompatible }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.asset.name < $1.asset.name
        }
        let best = scored.first(where: { $0.isCompatible && $0.score >= 25 })
        return AssetRecommendation(all: scored, best: best)
    }

    func score(_ asset: GHAsset) -> ScoredAsset {
        let name = asset.name.lowercased()
        let ext = asset.fileExtension
        let tokens = Self.tokenize(name)
        var score = 0
        var reasons: [String] = []

        // 1. Hard exclusions.
        if Self.metaExts.contains(ext) {
            return ScoredAsset(asset: asset, score: -100, reasons: ["校验/元数据文件"], isCompatible: false)
        }
        if Self.foreignExts.contains(ext) {
            return ScoredAsset(asset: asset, score: -100, reasons: ["非 macOS 格式（.\(ext)）"], isCompatible: false)
        }
        if Self.isSourceArchive(name, tokens: tokens) {
            return ScoredAsset(asset: asset, score: -100, reasons: ["源码包"], isCompatible: false)
        }
        let hasMacToken = tokens.contains { Self.macTokens.contains($0) }
        if !hasMacToken, let foreign = tokens.first(where: { Self.foreignNameTokens.contains($0) }) {
            return ScoredAsset(asset: asset, score: -100, reasons: ["面向 \(foreign) 平台"], isCompatible: false)
        }

        // 2. Package format.
        switch ext {
        case "dmg":
            score += 50; reasons.append("DMG 安装镜像")
        case "pkg":
            score += 40; reasons.append("PKG 安装包")
        case "zip":
            score += 30; reasons.append("ZIP 压缩包")
        case "app":
            score += 25
        case "":
            // Bare binary, e.g. "tool-darwin-arm64".
            score += hasMacToken ? 10 : -20
        default:
            score -= 5
        }

        // 3. macOS keywords.
        if hasMacToken {
            score += 20; reasons.append("面向 macOS")
        } else if ext == "zip" || ext == "pkg" || ext == "dmg" {
            // Format alone is a weak signal – many projects only ship mac builds as plain zip.
            score += 0
        }

        // 4. Architecture.
        let isARM = tokens.contains { Self.armTokens.contains($0) }
        let isIntel = tokens.contains { Self.intelTokens.contains($0) }
        let isUniversal = tokens.contains { Self.universalTokens.contains($0) }

        switch system.arch {
        case .arm64:
            if isUniversal { score += 28; reasons.append("通用版（同时支持 Apple Silicon 与 Intel）") }
            else if isARM && !isIntel { score += 35; reasons.append("匹配 Apple Silicon") }
            else if isIntel && !isARM { score -= 25; reasons.append("仅 Intel 版本（需 Rosetta）") }
        case .x86_64:
            if isUniversal { score += 28; reasons.append("通用版（同时支持 Apple Silicon 与 Intel）") }
            else if isIntel && !isARM { score += 35; reasons.append("匹配 Intel") }
            else if isARM && !isIntel { score -= 60; reasons.append("仅 Apple Silicon 版本，不适用于 Intel Mac") }
        }
        if !isARM && !isIntel && !isUniversal && hasMacToken {
            score += 8; reasons.append("未标注架构，通常为通用版")
        }

        // 5. Minimum macOS version hints such as "macos12" or "macos-13".
        if let minOS = Self.minimumMacOS(in: name) {
            if minOS > system.osMajor {
                score -= 40; reasons.append("需要 macOS \(minOS)+，当前为 \(system.osMajor)")
            } else {
                score += 4; reasons.append("兼容 macOS \(system.osVersionString)")
            }
        }

        // 6. Penalise debug / nightly / symbols.
        for bad in ["debug", "symbols", "dsym", "nightly", "portable", "cli-only"] where tokens.contains(bad) {
            score -= 15; reasons.append("非常规版本（\(bad)）")
        }

        // Tiny files are almost never the app itself.
        if asset.size > 0 && asset.size < 50_000 && ext != "pkg" {
            score -= 30
        }

        if reasons.isEmpty { reasons.append("无法确认适配性") }
        return ScoredAsset(asset: asset, score: score, reasons: reasons, isCompatible: true)
    }

    // MARK: helpers

    static func tokenize(_ lowerName: String) -> [String] {
        lowerName
            .replacingOccurrences(of: ".", with: "-")
            .split(whereSeparator: { "-_ +()[]".contains($0) })
            .map(String.init)
    }

    static func isSourceArchive(_ name: String, tokens: [String]) -> Bool {
        if tokens.contains("source") || tokens.contains("sources") || tokens.contains("src") { return true }
        // GitHub's auto-generated "Source code (zip)" assets are not part of `assets`, but some projects mimic the name.
        return name == "source code.zip" || name == "source code.tar.gz"
    }

    /// Detects "macos12", "macos-13", "macos_14" and returns the major version.
    static func minimumMacOS(in name: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:macos|osx|mac)[-_ ]?(1[0-9]|2[0-9])(?:[^0-9]|$)"#) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let m = regex.firstMatch(in: name, range: range),
              let r = Range(m.range(at: 1), in: name),
              let v = Int(name[r]) else { return nil }
        return v
    }
}
