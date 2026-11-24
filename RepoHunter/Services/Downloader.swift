import Foundation
import AppKit

/// Download manager built on a single URLSession with a delegate.
/// Supports pause / resume (resume data), cancel, progress + speed and persistent history.
@MainActor
final class Downloader: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    /// Where files land. Persisted in UserDefaults.
    @Published var destination: URL {
        didSet { UserDefaults.standard.set(destination.path, forKey: Self.destKey) }
    }

    private static let destKey = "downloadDirectory"
    private static let historyKey = "downloadHistory.v1"

    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var speedSamples: [UUID: (time: Date, bytes: Int64)] = [:]

    override init() {
        if let p = UserDefaults.standard.string(forKey: Self.destKey), !p.isEmpty {
            destination = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        loadHistory()
    }

    // MARK: Public API

    var activeCount: Int { items.filter { $0.state == .downloading || $0.state == .queued || $0.state == .paused }.count }

    func item(id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    /// Most recent non-cancelled item for the same repo + asset, used to show state on buttons.
    func latest(repo: String, asset: String) -> DownloadItem? {
        items.first { $0.repoFullName == repo && $0.assetName == asset }
    }

    @discardableResult
    func start(asset: GHAsset, repo: String, version: String?) -> DownloadItem? {
        guard let url = asset.downloadURL else { return nil }
        // Do not start a duplicate while one is running for the same asset.
        if let existing = items.first(where: {
            $0.repoFullName == repo && $0.assetName == asset.name && ($0.isActive || $0.state == .paused)
        }) { return existing }

        var item = DownloadItem(repoFullName: repo, assetName: asset.name, version: version, url: url, expectedSize: asset.size)
        item.state = .downloading
        items.insert(item, at: 0)
        launch(item.id, url: url)
        saveHistory()
        return item
    }

    func pause(_ id: UUID) {
        guard let task = tasks[id] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.resumeData[id] = data }
                self.update(id) {
                    $0.state = .paused
                    $0.speed = 0
                }
                self.tasks[id] = nil
                self.speedSamples[id] = nil
                self.saveHistory()
            }
        })
    }

    func resume(_ id: UUID) {
        guard let item = item(id: id), item.state == .paused || item.state == .failed || item.state == .cancelled else { return }
        update(id) { $0.state = .downloading; $0.errorMessage = nil }
        if let data = resumeData[id] {
            let task = session.downloadTask(withResumeData: data)
            register(task, for: id)
            task.resume()
        } else {
            update(id) { $0.bytesReceived = 0 }
            launch(id, url: item.url)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        resumeData[id] = nil
        speedSamples[id] = nil
        update(id) { $0.state = .cancelled; $0.speed = 0 }
        saveHistory()
    }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        if let item = item(id: id) {
            if deleteFile, let url = item.localURL {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            if item.isActive || item.state == .paused { tasks[id]?.cancel() }
        }
        tasks[id] = nil
        resumeData[id] = nil
        items.removeAll { $0.id == id }
        saveHistory()
    }

    func clearFinished() {
        items.removeAll { !($0.isActive || $0.state == .paused) }
        saveHistory()
    }

    // MARK: Post-download actions

    func revealInFinder(_ id: UUID) {
        guard let url = item(id: id)?.localURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ id: UUID) {
        guard let url = item(id: id)?.localURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Mounts a .dmg through hdiutil and reveals the mounted volume.
    func mountDMG(at url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["attach", url.path, "-autoopen", "-nobrowse"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    // Fall back to Finder's own handler (handles EULA prompts etc.).
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            } catch {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: Internals

    private func launch(_ id: UUID, url: URL) {
        var req = URLRequest(url: url)
        req.setValue("RepoHunter-macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: req)
        register(task, for: id)
        task.resume()
    }

    private func register(_ task: URLSessionDownloadTask, for id: UUID) {
        task.taskDescription = id.uuidString
        tasks[id] = task
        speedSamples[id] = (Date(), item(id: id)?.bytesReceived ?? 0)
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[idx])
    }

    private func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var target = destination.appendingPathComponent(name)
        guard fm.fileExists(atPath: target.path) else { return target }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        repeat {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            target = destination.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: target.path)
        return target
    }

    // MARK: Persistence

    private func saveHistory() {
        let keep = Array(items.prefix(200))
        if let data = try? JSONEncoder().encode(keep) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              var saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        // Transfers cannot survive an app restart; mark them as paused so the user can restart them.
        for i in saved.indices where saved[i].state == .downloading || saved[i].state == .queued {
            saved[i].state = .paused
            saved[i].speed = 0
        }
        items = saved
    }

    // MARK: Delegate callbacks (hopped to main actor)

    fileprivate func handleProgress(id: UUID, written: Int64, total: Int64) {
        let now = Date()
        var speed: Double?
        if let sample = speedSamples[id] {
            let dt = now.timeIntervalSince(sample.time)
            if dt >= 0.5 {
                let inst = Double(written - sample.bytes) / dt
                let prev = item(id: id)?.speed ?? 0
                speed = prev > 0 ? prev * 0.6 + inst * 0.4 : inst   // smoothed
                speedSamples[id] = (now, written)
            }
        } else {
            speedSamples[id] = (now, written)
        }
        update(id) {
            $0.bytesReceived = written
            if total > 0 { $0.totalBytes = total }
            if let speed { $0.speed = max(0, speed) }
            $0.state = .downloading
        }
    }

    fileprivate func handleFinished(id: UUID, tempFile: URL, suggestedName: String?, status: Int) {
        guard let item = item(id: id) else { return }
        if status >= 400 {
            update(id) { $0.state = .failed; $0.errorMessage = "服务器返回 HTTP \(status)"; $0.speed = 0 }
            saveHistory()
            return
        }
        let target = uniqueDestination(for: item.assetName.isEmpty ? (suggestedName ?? "download") : item.assetName)
        do {
            try FileManager.default.moveItem(at: tempFile, to: target)
            update(id) {
                $0.state = .completed
                $0.localPath = target.path
                $0.finishedAt = Date()
                $0.speed = 0
                $0.bytesReceived = max($0.bytesReceived, (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0)
                $0.totalBytes = $0.bytesReceived
            }
            tasks[id] = nil
            resumeData[id] = nil
            speedSamples[id] = nil
            saveHistory()
            NotificationCenter.default.post(name: .downloadCompleted, object: nil, userInfo: ["id": id])
            if UserDefaults.standard.object(forKey: "autoMountDMG") as? Bool ?? true, target.pathExtension.lowercased() == "dmg" {
                mountDMG(at: target)
            }
            if UserDefaults.standard.bool(forKey: "autoRevealAfterDownload") {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        } catch {
            update(id) { $0.state = .failed; $0.errorMessage = "无法保存文件：\(error.localizedDescription)"; $0.speed = 0 }
            saveHistory()
        }
    }

    fileprivate func handleError(id: UUID, error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
            // Pause / cancel paths update state themselves.
            if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[id] = data }
            return
        }
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[id] = data }
        update(id) {
            $0.state = .failed
            $0.errorMessage = error.localizedDescription
            $0.speed = 0
        }
        tasks[id] = nil
        saveHistory()
    }
}

extension Notification.Name {
    static let downloadCompleted = Notification.Name("RepoHunter.downloadCompleted")
}

extension Downloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let s = downloadTask.taskDescription, let id = UUID(uuidString: s) else { return }
        Task { @MainActor in self.handleProgress(id: id, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let s = downloadTask.taskDescription, let id = UUID(uuidString: s) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let suggested = downloadTask.response?.suggestedFilename
        // The temp file is deleted when this method returns, so move it somewhere stable synchronously.
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("repohunter-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
        } catch {
            Task { @MainActor in self.handleError(id: id, error: error) }
            return
        }
        Task { @MainActor in self.handleFinished(id: id, tempFile: stable, suggestedName: suggested, status: status) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let s = task.taskDescription, let id = UUID(uuidString: s) else { return }
        Task { @MainActor in self.handleError(id: id, error: error) }
    }
}
