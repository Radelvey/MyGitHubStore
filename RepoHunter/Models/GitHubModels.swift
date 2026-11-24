import Foundation

// MARK: - GitHub API models

struct GHOwner: Codable, Hashable {
    let login: String
    let avatarUrl: String?
}

struct GHLicense: Codable, Hashable {
    let name: String?
    let spdxId: String?
}

struct GHRepo: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let htmlUrl: String
    let stargazersCount: Int
    let forksCount: Int
    let language: String?
    let topics: [String]?
    let updatedAt: Date?
    let pushedAt: Date?
    let owner: GHOwner
    let license: GHLicense?
    let homepage: String?
    let defaultBranch: String?
    let archived: Bool?

    var htmlURL: URL? { URL(string: htmlUrl) }
    var avatarURL: URL? { owner.avatarUrl.flatMap { URL(string: $0) } }
    var branch: String { defaultBranch ?? "main" }
    var sourceZipURL: URL? {
        URL(string: "https://github.com/\(fullName)/archive/refs/heads/\(branch).zip")
    }
}

struct GHSearchResponse: Codable {
    let totalCount: Int
    let incompleteResults: Bool?
    let items: [GHRepo]
}

struct GHAsset: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let size: Int64
    let downloadCount: Int
    let browserDownloadUrl: String
    let contentType: String?

    var downloadURL: URL? { URL(string: browserDownloadUrl) }
    var sizeText: String { Fmt.bytes(size) }

    /// Lower-cased extension, understanding double extensions such as `tar.gz`.
    var fileExtension: String {
        let lower = name.lowercased()
        for double in ["tar.gz", "tar.xz", "tar.bz2", "tar.zst", "intoto.jsonl"] where lower.hasSuffix("." + double) {
            return double
        }
        return (lower as NSString).pathExtension
    }
}

struct GHRelease: Codable, Identifiable, Hashable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let htmlUrl: String
    let assets: [GHAsset]

    var title: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return tagName
    }
    var htmlURL: URL? { URL(string: htmlUrl) }
}

/// Optional values cannot be cached directly (404 is a legitimate answer), so wrap them.
struct Box<T: Codable>: Codable {
    let value: T?
}

// MARK: - JSON coding

enum GitHubCoding {
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
