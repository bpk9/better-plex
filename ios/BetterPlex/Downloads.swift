import Foundation
import UIKit

enum DownloadState: String, Codable { case queued, downloading, paused, failed, complete }
struct DownloadJob: Codable, Identifiable {
    var id: String
    var serverID: String
    var mediaID: String
    var partKey: String
    var title: String
    var filename: String
    var expected: Int64
    var received: Int64 = 0
    var state: DownloadState = .queued
    var error: String?
    var taskID: Int?
    var historyOwner: String?
    var multipart: Bool?
    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
}
struct DownloadSelection: Identifiable {
    let id = UUID()
    var item: MediaItem
    var version: MediaVersion
}

final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var storageError: String?
    @Published var allowCellular: Bool = UserDefaults.standard.bool(forKey: "cellular") {
        didSet { UserDefaults.standard.set(allowCellular, forKey: "cellular") }
    }
    var backgroundCompletion: (() -> Void)?
    private var restored = false
    private var pausing: Set<String> = []
    private var resumeAfterPause: Set<String> = []
    private var forgetResumeIDs: Set<String> = []
    private let fm = FileManager.default
    private let root: URL
    private let privateRoot: URL
    private var manifest: URL { privateRoot.appendingPathComponent("downloads.json") }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.briankasper.betterplex.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    override init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        privateRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Transfers", isDirectory: true)
        super.init()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: privateRoot, withIntermediateDirectories: true)
            for var directory in [root, privateRoot] {
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            }
            if fm.fileExists(atPath: manifest.path) { jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: manifest)) }
            for index in jobs.indices where jobs[index].state == .complete && !fm.fileExists(atPath: file(jobs[index]).path) {
                jobs[index].state = .failed; jobs[index].error = "The downloaded file was moved or removed. Download it again."
            }
        } catch { storageError = "Could not restore downloads: \(error.localizedDescription)" }
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for task in tasks {
                    guard let id = task.taskDescription, let index = self.jobs.firstIndex(where: { $0.id == id }) else { task.cancel(); continue }
                    if self.jobs[index].state == .downloading {
                        self.jobs[index].taskID = task.taskIdentifier
                    } else { task.cancel() }
                }
                let liveIDs = Set(tasks.compactMap(\.taskDescription))
                for index in self.jobs.indices where self.jobs[index].state == .downloading && !liveIDs.contains(self.jobs[index].id) {
                    self.jobs[index].state = .paused
                    self.jobs[index].taskID = nil
                    self.jobs[index].error = "Transfer interrupted. Tap Resume to continue."
                }
                self.restored = true
                self.save(); self.pump()
            }
        }
    }
    var completedBytes: Int64 { jobs.filter { $0.state == .complete }.reduce(0) { $0 + $1.received } }
    var activeCount: Int { jobs.filter { [.queued, .downloading].contains($0.state) }.count }
    func file(_ job: DownloadJob) -> URL { root.appendingPathComponent(job.filename) }
    private func resumeFile(_ id: String) -> URL { privateRoot.appendingPathComponent(id + ".resume") }
    func bindHistoryOwner(_ id: String, owner: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].historyOwner == nil else { return }
        jobs[index].historyOwner = owner; save()
    }
    func enqueue(_ selections: [DownloadSelection], server: ServerSession) throws {
        try SecureStore.write(JSONEncoder().encode(server), key: "server-\(server.id)")
        var additions: [DownloadJob] = []
        for selection in selections {
            let parts = selection.version.Part ?? []
            guard !parts.isEmpty else { throw PlexError.message("\(selection.item.title) has no downloadable file.") }
            for (partIndex, part) in parts.enumerated() {
                _ = try PlexAPI.url(part.key, server: server)
                guard !jobs.contains(where: { $0.serverID == server.id && $0.partKey == part.key }), !additions.contains(where: { $0.partKey == part.key }) else { continue }
                let id = UUID().uuidString
                let ext = (part.container ?? selection.version.container ?? URL(fileURLWithPath: part.file ?? part.key).pathExtension).lowercased().filter { $0.isLetter || $0.isNumber }
                let title = selection.item.downloadTitle + (parts.count > 1 ? " — Part \(partIndex + 1)" : "")
                let clean = title.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()" )).inverted).joined(separator: " ").prefix(120)
                additions.append(DownloadJob(id: id, serverID: server.id, mediaID: selection.item.id, partKey: part.key, title: title, filename: "\(clean)-\(id.prefix(8)).\(ext.isEmpty ? "mp4" : ext)", expected: part.size ?? 0, historyOwner: server.historyOwner, multipart: parts.count > 1))
            }
        }
        let needed = additions.reduce(Int64(0)) { $0 + $1.expected } + jobs.filter { [.queued, .downloading].contains($0.state) }.reduce(0) { $0 + max(0, $1.expected - $1.received) }
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, needed > free {
            throw PlexError.message("Not enough storage. These downloads need \(byteString(needed)); \(byteString(free)) is available.")
        }
        jobs += additions
        save(); pump()
    }
    private func save() {
        do { try JSONEncoder().encode(jobs).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { storageError = "Could not save download progress: \(error.localizedDescription)" }
    }
    private func pump() {
        guard restored else { return }
        var slots = 2 - jobs.filter { $0.state == .downloading }.count
        for index in jobs.indices where jobs[index].state == .queued && slots > 0 {
            do {
                guard let data = SecureStore.read("server-\(jobs[index].serverID)") else { throw PlexError.message("Reconnect to this Plex server in Account, then retry.") }
                let server = try JSONDecoder().decode(ServerSession.self, from: data)
                let url = try PlexAPI.url(jobs[index].partKey, server: server, query: [URLQueryItem(name: "download", value: "1")])
                var request = PlexAPI.request(url, token: server.token)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                request.allowsCellularAccess = allowCellular
                let task: URLSessionDownloadTask
                if let resume = try? Data(contentsOf: resumeFile(jobs[index].id)) {
                    task = session.downloadTask(withResumeData: resume)
                } else { task = session.downloadTask(with: request) }
                task.taskDescription = jobs[index].id
                jobs[index].state = .downloading; jobs[index].error = nil; jobs[index].taskID = task.taskIdentifier
                slots -= 1
                save()
                task.resume()
            } catch { jobs[index].state = .failed; jobs[index].error = error.localizedDescription }
        }
        save()
    }
    func pauseAll(forgetResumeData: Bool = false) {
        if forgetResumeData {
            forgetResumeIDs.formUnion(jobs.map(\.id))
            for job in jobs { try? fm.removeItem(at: resumeFile(job.id)) }
        }
        for job in jobs where [.queued, .downloading].contains(job.state) { pause(job.id) }
    }
    func pause(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), [.queued, .downloading].contains(jobs[index].state) else { return }
        let taskID = jobs[index].taskID
        jobs[index].state = .paused; jobs[index].taskID = nil
        save()
        guard let taskID else { pump(); return }
        pausing.insert(id)
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskID }) as? URLSessionDownloadTask else {
                DispatchQueue.main.async { self.finishPause(id, data: nil) }; return
            }
            task.cancel { data in DispatchQueue.main.async { self.finishPause(id, data: data) } }
        }
    }
    private func finishPause(_ id: String, data: Data?) {
        if let data, !forgetResumeIDs.contains(id), jobs.contains(where: { $0.id == id }) { try? data.write(to: resumeFile(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        pausing.remove(id)
        if resumeAfterPause.remove(id) != nil { resume(id) }
        pump()
    }
    func resume(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), [.paused, .failed].contains(jobs[index].state) else { return }
        if pausing.contains(id) { resumeAfterPause.insert(id); return }
        forgetResumeIDs.remove(id)
        jobs[index].state = .queued; jobs[index].error = nil
        save(); pump()
    }
    func remove(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        resumeAfterPause.remove(id)
        session.getAllTasks { tasks in for task in tasks where task.taskDescription == id { task.cancel() } }
        try? fm.removeItem(at: file(job)); try? fm.removeItem(at: resumeFile(id))
        save(); pump()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let index = jobs.firstIndex(where: { $0.taskID == downloadTask.taskIdentifier && $0.state == .downloading }) else { return }
        jobs[index].received = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { jobs[index].expected = totalBytesExpectedToWrite }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = jobs.firstIndex(where: { $0.taskID == downloadTask.taskIdentifier && $0.state == .downloading }) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw PlexError.message("Invalid download response.") }
            guard (200..<300).contains(response.statusCode) else { throw PlexError.status(response.statusCode) }
            let contentType = response.mimeType ?? ""
            guard !["text/html", "application/json", "application/xml", "text/xml"].contains(contentType) else { throw PlexError.message("The server returned an error page instead of a media file.") }
            let size = (try fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, jobs[index].expected <= 0 || size == jobs[index].expected else { throw PlexError.message("The download was incomplete. Retry to fetch the full file.") }
            let target = file(jobs[index])
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: location, to: target)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            jobs[index].received = size; jobs[index].expected = size; jobs[index].state = .complete; jobs[index].error = nil
            try? fm.removeItem(at: resumeFile(jobs[index].id))
        } catch {
            jobs[index].state = .failed; jobs[index].error = error.localizedDescription
            try? fm.removeItem(at: resumeFile(jobs[index].id))
        }
        jobs[index].taskID = nil
        save(); pump()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let index = jobs.firstIndex(where: { $0.taskID == task.taskIdentifier && $0.state == .downloading }) else { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile(jobs[index].id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else { try? fm.removeItem(at: resumeFile(jobs[index].id)) }
        jobs[index].state = .failed; jobs[index].taskID = nil
        jobs[index].error = "Download interrupted. Check your connection and retry."
        save(); pump()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        save()
        let completion = backgroundCompletion; backgroundCompletion = nil
        completion?()
    }
}
final class ApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Downloads.shared.backgroundCompletion = completionHandler
    }
}
