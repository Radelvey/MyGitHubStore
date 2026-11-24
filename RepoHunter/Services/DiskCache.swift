import Foundation
import CryptoKit

/// Small JSON + binary cache in ~/Library/Caches/<bundle id>/RepoHunter.
/// Entries never expire on their own; `age` lets callers decide whether to refresh.
final class DiskCache {
    static let shared = DiskCache()

    private let dir: URL
    private let queue = DispatchQueue(label: "repohunter.diskcache")
    private let encoder = GitHubCoding.makeEncoder()
    private let decoder = GitHubCoding.makeDecoder()

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.repohunter.app", isDirectory: true)
            .appendingPathComponent("RepoHunter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String, ext: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(name).\(ext)")
    }

    // MARK: JSON

    func store<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        let url = fileURL(key, ext: "json")
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = fileURL(key, ext: "json")
        guard let data = queue.sync(execute: { try? Data(contentsOf: url) }) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Seconds since the entry was written, or nil if absent.
    func age(key: String) -> TimeInterval? {
        let url = fileURL(key, ext: "json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }

    // MARK: Binary (icons)

    func storeData(_ data: Data, key: String) {
        let url = fileURL(key, ext: "bin")
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    func loadData(key: String) -> Data? {
        let url = fileURL(key, ext: "bin")
        return queue.sync { try? Data(contentsOf: url) }
    }

    // MARK: Maintenance

    func sizeOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
