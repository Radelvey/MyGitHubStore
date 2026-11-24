import Foundation

// MARK: - Sidebar

enum RepoCategory: String, CaseIterable, Identifiable, Hashable {
    case all, swiftui, developer, productivity, menubar, media, utilities, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部 macOS 应用"
        case .swiftui: return "SwiftUI 应用"
        case .developer: return "开发者工具"
        case .productivity: return "效率"
        case .menubar: return "菜单栏"
        case .media: return "影音"
        case .utilities: return "实用工具"
        case .privacy: return "隐私与安全"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .swiftui: return "swift"
        case .developer: return "hammer"
        case .productivity: return "checklist"
        case .menubar: return "menubar.rectangle"
        case .media: return "play.rectangle"
        case .utilities: return "wrench.and.screwdriver"
        case .privacy: return "lock.shield"
        }
    }

    /// Extra qualifiers appended to the GitHub search query.
    var extraQuery: String {
        switch self {
        case .all: return "topic:macos"
        case .swiftui: return "topic:macos topic:swiftui"
        case .developer: return "topic:macos topic:developer-tools"
        case .productivity: return "topic:macos topic:productivity"
        case .menubar: return "topic:macos topic:menubar"
        case .media: return "topic:macos topic:media-player"
        case .utilities: return "topic:macos topic:utility"
        case .privacy: return "topic:macos topic:privacy"
        }
    }
}

enum SidebarItem: Hashable {
    case category(RepoCategory)
    case downloads
}

// MARK: - Search filters

enum SearchSort: String, CaseIterable, Identifiable {
    case stars, updated, bestMatch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stars: return "Stars 最多"
        case .updated: return "最近更新"
        case .bestMatch: return "最佳匹配"
        }
    }

    /// Value of the `sort` query parameter, nil for "best match".
    var apiValue: String? {
        switch self {
        case .stars: return "stars"
        case .updated: return "updated"
        case .bestMatch: return nil
        }
    }
}

enum LanguageFilter: String, CaseIterable, Identifiable {
    case any = ""
    case swift = "Swift"
    case objc = "Objective-C"
    case rust = "Rust"
    case go = "Go"
    case cpp = "C++"
    case c = "C"
    case typescript = "TypeScript"
    case javascript = "JavaScript"
    case kotlin = "Kotlin"
    case python = "Python"
    case dart = "Dart"

    var id: String { rawValue.isEmpty ? "any" : rawValue }
    var title: String { rawValue.isEmpty ? "所有语言" : rawValue }

    /// GitHub expects quotes around names with special characters (C++, Objective-C).
    var qualifier: String? {
        guard !rawValue.isEmpty else { return nil }
        return "language:\"\(rawValue)\""
    }
}

enum StarFilter: Int, CaseIterable, Identifiable {
    case any = 0, s10 = 10, s50 = 50, s100 = 100, s500 = 500, s1000 = 1000
    var id: Int { rawValue }
    var title: String { self == .any ? "不限 Stars" : "≥ \(rawValue) Stars" }
}

// MARK: - Load states

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Lightweight state of the "latest release" lookup used by list rows.
enum ReleaseState: Equatable {
    case loading
    case none
    case loaded(version: String, prerelease: Bool, hasMacAsset: Bool)
    case failed
}
