import Foundation
import SwiftUI
import AVFoundation
import Network

struct WatchUpdate: Codable, Equatable {
    var revision = UUID()
    var sessionID: String
    var state: String
    var kind: String = "timeline"
    var offset: Int
    var duration: Int
    var updatedAt: Date
    var offline = false
}
struct WatchRecord: Codable, Identifiable {
    var id: String
    var serverID: String
    var mediaID: String
    var owner: String
    var offset: Int = 0
    var duration: Int = 0
    var watched = false
    var updatedAt: Date = .distantPast
    var pending: WatchUpdate?
    var localOnly = false
    var label: String {
        if watched && offset == 0 { return "Watched" }
        if offset > 0 { return "Resume at \(playbackTime(offset))" }
        return watched ? "Watched" : "Unwatched"
    }
}
func playbackTime(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1000)
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
struct HistoryTransport {
    var read: (String, ServerSession) async throws -> MediaItem
    var send: (WatchRecord, WatchUpdate, ServerSession) async throws -> Void
    static var live: HistoryTransport {
        HistoryTransport(read: { id, server in
            var request = PlexAPI.request(try PlexAPI.url("/library/metadata/\(id)", server: server), token: server.token)
            request.timeoutInterval = 3
            let envelope: PlexEnvelope = try await PlexAPI.fetch(request)
            guard let item = envelope.MediaContainer.Metadata?.first else { throw PlexError.message("Playback history is unavailable for this title.") }
            return item
        }, send: { record, update, server in
            let path = update.kind == "timeline" ? "/:/timeline" : update.kind == "watched" ? "/:/scrobble" : "/:/unscrobble"
            let values: [String: String] = update.kind == "timeline" ? [
                "ratingKey": record.mediaID, "key": "/library/metadata/\(record.mediaID)",
                "state": update.offline ? "stopped" : update.state,
                "time": String(update.offset), "duration": String(update.duration),
                "offline": update.offline ? "1" : "0", "updated": String(Int(update.updatedAt.timeIntervalSince1970))
            ] : ["key": record.mediaID, "identifier": "com.plexapp.plugins.library"]
            var request = PlexAPI.request(try PlexAPI.url(path, server: server, query: values.map { URLQueryItem(name: $0.key, value: $0.value) }), token: server.token)
            request.httpMethod = update.kind == "timeline" ? "POST" : "PUT"
            request.timeoutInterval = 8
            request.setValue(update.sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PlexError.message("Plex could not save playback history. It will retry when connected.") }
        })
    }
}

@MainActor final class PlaybackHistory: ObservableObject {
    static let shared = PlaybackHistory()
    @Published private(set) var records: [String: WatchRecord] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    private let fileURL: URL
    private let serverProvider: (String) -> ServerSession?
    private let transport: HistoryTransport
    private let automaticSync: Bool
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var activeSessions: Set<String> = []
    private var monitor: NWPathMonitor?
    var pendingCount: Int { records.values.filter { $0.pending != nil }.count }

    nonisolated static func savedServer(_ id: String) -> ServerSession? {
        guard let data = SecureStore.read("server-\(id)") else { return nil }
        return try? JSONDecoder().decode(ServerSession.self, from: data)
    }
    init(fileURL: URL? = nil, transport: HistoryTransport = .live, serverProvider: @escaping (String) -> ServerSession? = PlaybackHistory.savedServer, monitorNetwork: Bool = true, automaticSync: Bool = true) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("playback-history.json")
        self.transport = transport; self.serverProvider = serverProvider; self.automaticSync = automaticSync
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                records = try JSONDecoder().decode([String: WatchRecord].self, from: Data(contentsOf: self.fileURL))
                for id in records.keys where records[id]?.pending != nil { records[id]?.pending?.offline = true }
            }
        } catch { lastError = "Could not read saved playback history: \(error.localizedDescription)" }
        if monitorNetwork {
            let monitor = NWPathMonitor(); self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied { Task { @MainActor [weak self] in self?.sync() } }
            }
            monitor.start(queue: DispatchQueue(label: "better-plex.history-network"))
        }
    }
    private func key(serverID: String, mediaID: String, owner: String) -> String { "\(owner)|\(serverID)|\(mediaID)" }
    private func isMultipart(_ job: DownloadJob) -> Bool { job.multipart == true || (job.multipart == nil && job.title.contains(" — Part ")) }
    func owner(for job: DownloadJob) -> String { job.historyOwner ?? serverProvider(job.serverID)?.historyOwner ?? "local-device" }
    func record(for job: DownloadJob) -> WatchRecord? {
        records[key(serverID: job.serverID, mediaID: isMultipart(job) ? job.mediaID + "|" + job.partKey : job.mediaID, owner: owner(for: job))]
    }
    func record(for item: MediaItem, server: ServerSession) -> WatchRecord? {
        records[key(serverID: server.id, mediaID: item.id, owner: server.historyOwner)]
    }
    func ingest(_ item: MediaItem, server: ServerSession) {
        guard !item.isContainer else { return }
        let id = key(serverID: server.id, mediaID: item.id, owner: server.historyOwner)
        guard records[id]?.pending == nil else { return }
        records[id] = WatchRecord(id: id, serverID: server.id, mediaID: item.id, owner: server.historyOwner, offset: item.viewOffset ?? 0, duration: item.duration ?? 0, watched: (item.viewCount ?? 0) > 0, updatedAt: Date(timeIntervalSince1970: item.lastViewedAt ?? 0))
        save()
    }
    func prepare(_ job: DownloadJob) async -> WatchRecord? {
        guard !isMultipart(job), let server = serverProvider(job.serverID), server.historyOwner == owner(for: job) else { return record(for: job) }
        if let item = try? await transport.read(job.mediaID, server) { ingest(item, server: server) }
        return record(for: job)
    }
    func beginSession(_ session: String) { activeSessions.insert(session) }
    func recordPlayback(job: DownloadJob, session: String, offset: Int, duration: Int, state: String, finished: Bool = false) {
        guard duration > 0, offset >= 0 else { return }
        let owner = owner(for: job)
        let localOnly = isMultipart(job) || owner == "local-device"
        let id = key(serverID: job.serverID, mediaID: isMultipart(job) ? job.mediaID + "|" + job.partKey : job.mediaID, owner: owner)
        var value = records[id] ?? WatchRecord(id: id, serverID: job.serverID, mediaID: job.mediaID, owner: owner)
        // Don't turn an opened-but-never-played item into a history entry.
        guard offset > 0 || value.offset > 0 || finished else { return }
        value.offset = finished ? 0 : min(offset, duration)
        value.duration = duration; value.updatedAt = Date(); value.localOnly = localOnly
        if finished { value.watched = true }
        if !localOnly {
            value.pending = WatchUpdate(sessionID: session, state: state, offset: min(offset, duration), duration: duration, updatedAt: value.updatedAt)
        }
        records[id] = value
        save(); if automaticSync { sync() }
    }
    func mark(_ item: MediaItem, server: ServerSession, watched: Bool) {
        let id = key(serverID: server.id, mediaID: item.id, owner: server.historyOwner)
        var value = records[id] ?? WatchRecord(id: id, serverID: server.id, mediaID: item.id, owner: server.historyOwner)
        value.offset = 0; value.watched = watched; value.updatedAt = Date()
        value.pending = WatchUpdate(sessionID: UUID().uuidString, state: "stopped", kind: watched ? "watched" : "unwatched", offset: 0, duration: value.duration, updatedAt: value.updatedAt)
        records[id] = value; save(); if automaticSync { sync() }
    }
    func mark(_ job: DownloadJob, watched: Bool) {
        guard let server = serverProvider(job.serverID), owner(for: job) == server.historyOwner else {
            lastError = "Reconnect to the Plex account used for this download to change its watched status."; return
        }
        mark(MediaItem(ratingKey: job.mediaID, title: job.title, type: "movie"), server: server, watched: watched)
    }
    func cancelSync() {
        generation = UUID(); task?.cancel(); task = nil; syncing = false
    }
    func sync() {
        guard task == nil, pendingCount > 0 else { return }
        let generation = generation
        syncing = true
        task = Task { [weak self] in
            guard let self else { return }
            await flush(generation: generation)
            guard generation == self.generation else { return }
            self.task = nil; syncing = false
        }
    }
    // Serialize updates and acknowledge only the exact revision actually sent.
    func flush(generation: UUID? = nil) async {
        let expectedGeneration = generation ?? self.generation
        for id in Array(records.keys).sorted() {
            var attempts = 0
            while let value = records[id], var update = value.pending, attempts < 3 {
                guard !Task.isCancelled, expectedGeneration == self.generation else { return }
                guard let server = serverProvider(value.serverID), server.historyOwner == value.owner, !value.localOnly else { break }
                attempts += 1
                if !activeSessions.contains(update.sessionID) { update.offline = true }
                do {
                    if update.offline, update.kind == "timeline" {
                        let remote = try await transport.read(value.mediaID, server)
                        guard records[id]?.pending?.revision == update.revision else { continue }
                        // A newer viewing on another device wins over an older offline checkpoint.
                        if let lastViewed = remote.lastViewedAt, lastViewed > update.updatedAt.timeIntervalSince1970 + 1 {
                            records[id]?.pending = nil
                            ingest(remote, server: server)
                            break
                        }
                    }
                    guard !Task.isCancelled, expectedGeneration == self.generation, serverProvider(value.serverID)?.historyOwner == value.owner else { return }
                    try await transport.send(value, update, server)
                    guard !Task.isCancelled, expectedGeneration == self.generation else { return }
                    if update.state == "stopped" { activeSessions.remove(update.sessionID) }
                    if records[id]?.pending?.revision == update.revision { records[id]?.pending = nil }
                    lastError = nil; save()
                } catch {
                    if update.state == "stopped" { activeSessions.remove(update.sessionID) }
                    if records[id]?.pending?.revision == update.revision { records[id]?.pending?.offline = true }
                    lastError = "Playback saved on this device. Plex sync will retry when connected."
                    save(); break
                }
            }
        }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { lastError = "Could not save playback history: \(error.localizedDescription)" }
    }
}

@MainActor final class OfflinePlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error: String?
    @Published var resumeLabel: String?
    private let history: PlaybackHistory
    private var session = UUID().uuidString
    private var job: DownloadJob?
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var duration = 0
    private var lastOffset = 0
    private var finished = false
    private var stopped = false
    init(history: PlaybackHistory? = nil) { self.history = history ?? .shared }
    func open(job: DownloadJob, url: URL) async {
        guard self.job == nil else { return }
        self.job = job
        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw PlexError.message("This original file needs another player. Use Save / Open. Playback in other apps cannot sync automatically.") }
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0 else { throw PlexError.message("This file has no playable duration.") }
            duration = Int(seconds * 1000)
            let checkpoint = await history.prepare(job)
            try Task.checkCancellation()
            guard !stopped else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            if let offset = checkpoint?.offset, offset > 0, offset < duration - 1000 {
                await player.seek(to: CMTime(value: Int64(offset), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
                lastOffset = offset; resumeLabel = "Resumed at \(playbackTime(offset))"
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            history.beginSession(session)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1000), queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkpoint() }
            }
            rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.checkpoint() }
            }
            player.play()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func checkpoint(state: String? = nil) {
        guard !stopped, let player, let job, player.currentItem?.status == .readyToPlay else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        let offset = min(duration, Int(seconds * 1000))
        if finished {
            guard player.timeControlStatus == .playing, offset < duration - 1000 else { return }
            finished = false; session = UUID().uuidString; history.beginSession(session)
        }
        lastOffset = offset
        history.recordPlayback(job: job, session: session, offset: lastOffset, duration: duration, state: state ?? (player.timeControlStatus == .playing ? "playing" : "paused"))
    }
    func ended() {
        guard !finished, !stopped, let job else { return }
        finished = true
        history.recordPlayback(job: job, session: session, offset: duration, duration: duration, state: "stopped", finished: true)
    }
    func stop() {
        guard !stopped else { return }
        checkpoint(state: "stopped")
        stopped = true; player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }
        rateObserver?.invalidate(); rateObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
