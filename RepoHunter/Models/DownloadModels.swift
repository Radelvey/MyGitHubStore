import Foundation

enum DownloadState: String, Codable {
    case queued, downloading, paused, completed, failed, cancelled

    var title: String {
        switch self {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct DownloadItem: Identifiable, Codable, Hashable {
    let id: UUID
    var repoFullName: String
    var assetName: String
    var version: String?
    var url: URL
    var expectedSize: Int64
    var state: DownloadState
    var bytesReceived: Int64
    var totalBytes: Int64
    var localPath: String?
    var errorMessage: String?
    var createdAt: Date
    var finishedAt: Date?
    /// Bytes per second. Runtime only, never persisted.
    var speed: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, repoFullName, assetName, version, url, expectedSize, state
        case bytesReceived, totalBytes, localPath, errorMessage, createdAt, finishedAt
    }

    init(id: UUID = UUID(),
         repoFullName: String,
         assetName: String,
         version: String?,
         url: URL,
         expectedSize: Int64) {
        self.id = id
        self.repoFullName = repoFullName
        self.assetName = assetName
        self.version = version
        self.url = url
        self.expectedSize = expectedSize
        self.state = .queued
        self.bytesReceived = 0
        self.totalBytes = expectedSize
        self.localPath = nil
        self.errorMessage = nil
        self.createdAt = Date()
        self.finishedAt = nil
    }

    var progress: Double {
        let total = totalBytes > 0 ? totalBytes : expectedSize
        guard total > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(total))
    }

    var isActive: Bool { state == .queued || state == .downloading }
    var isFinishedOK: Bool { state == .completed }
    var localURL: URL? { localPath.map { URL(fileURLWithPath: $0) } }
    var fileExists: Bool {
        guard let p = localPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }
    var isDMG: Bool { assetName.lowercased().hasSuffix(".dmg") }
}
