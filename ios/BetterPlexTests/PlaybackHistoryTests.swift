import XCTest
@testable import BetterPlex

@MainActor final class PlaybackHistoryTests: XCTestCase {
    var server: ServerSession { ServerSession(id: "server-A", name: "Test", url: URL(string: "https://example.invalid")!, token: "test-token", userID: "account-A") }
    func job(multipart: Bool = false) -> DownloadJob {
        DownloadJob(id: "download-A", serverID: server.id, mediaID: "42", partKey: "/parts/1", title: "Example", filename: "example.mp4", expected: 100, historyOwner: server.historyOwner, multipart: multipart)
    }
    func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json") }
    func remote(offset: Int = 0, watched: Bool = false, time: Double = 0) -> MediaItem {
        MediaItem(ratingKey: "42", title: "Example", type: "movie", duration: 100_000, viewOffset: offset, viewCount: watched ? 1 : 0, lastViewedAt: time)
    }
    func testOfflineProgressSurvivesRestartAndRetriesWithOriginalTimestamp() async throws {
        let file = location()
        let transport = HistoryTransport(read: { _, _ in throw URLError(.notConnectedToInternet) }, send: { _, _, _ in XCTFail("Offline read should prevent sending") })
        let store = PlaybackHistory(fileURL: file, transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.recordPlayback(job: job(), session: "session", offset: 40_000, duration: 100_000, state: "stopped")
        let recordedAt = try XCTUnwrap(store.record(for: job())?.updatedAt)
        await store.flush()
        XCTAssertEqual(store.pendingCount, 1)
        var updates: [WatchUpdate] = []
        let retry = HistoryTransport(read: { _, _ in self.remote() }, send: { _, update, _ in updates.append(update) })
        let restored = PlaybackHistory(fileURL: file, transport: retry, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        XCTAssertEqual(restored.record(for: job())?.offset, 40_000)
        await restored.flush()
        XCTAssertEqual(restored.pendingCount, 0)
        XCTAssertEqual(updates.first?.offset, 40_000)
        XCTAssertEqual(updates.first?.updatedAt, recordedAt)
        XCTAssertEqual(updates.first?.offline, true)
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains("test-token"))
    }
    func testPullsPlexResumeButNeverReplacesUnsentLocalProgress() async {
        let transport = HistoryTransport(read: { _, _ in self.remote(offset: 12_000) }, send: { _, _, _ in })
        let store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        let imported = await store.prepare(job())
        XCTAssertEqual(imported?.offset, 12_000)
        store.recordPlayback(job: job(), session: "session", offset: 20_000, duration: 100_000, state: "paused")
        let retained = await store.prepare(job())
        XCTAssertEqual(retained?.offset, 20_000)
    }
    func testChangedAccountDoesNotReceiveOldHistory() async {
        var other = server; other.userID = "account-B"
        var sends = 0
        let transport = HistoryTransport(read: { _, _ in self.remote() }, send: { _, _, _ in sends += 1 })
        let store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in other }, monitorNetwork: false, automaticSync: false)
        store.recordPlayback(job: job(), session: "session", offset: 10_000, duration: 100_000, state: "stopped")
        await store.flush()
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertNil(store.record(for: remote(), server: other))
    }
    func testNewerPlexViewingWinsOverOldOfflineCheckpoint() async {
        var sends = 0
        let transport = HistoryTransport(read: { _, _ in self.remote(offset: 75_000, time: Date().timeIntervalSince1970 + 30) }, send: { _, _, _ in sends += 1 })
        let store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.recordPlayback(job: job(), session: "session", offset: 25_000, duration: 100_000, state: "stopped")
        await store.flush()
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(store.record(for: job())?.offset, 75_000)
        XCTAssertEqual(store.pendingCount, 0)
    }
    func testInFlightAcknowledgementCannotEraseNewerCheckpoint() async {
        var store: PlaybackHistory!
        var offsets: [Int] = []
        let transport = HistoryTransport(read: { _, _ in self.remote() }, send: { _, update, _ in
            offsets.append(update.offset)
            if offsets.count == 1 { store.recordPlayback(job: self.job(), session: "session", offset: 65_000, duration: 100_000, state: "stopped") }
        })
        store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.recordPlayback(job: job(), session: "session", offset: 35_000, duration: 100_000, state: "stopped")
        await store.flush()
        XCTAssertEqual(offsets, [35_000, 65_000])
        XCTAssertEqual(store.record(for: job())?.offset, 65_000)
        XCTAssertEqual(store.pendingCount, 0)
    }
    func testFailedWriteKeepsPendingAndCompletionUsesTimeline() async {
        var update: WatchUpdate?
        let transport = HistoryTransport(read: { _, _ in self.remote() }, send: { _, value, _ in update = value; throw URLError(.badServerResponse) })
        let store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.recordPlayback(job: job(), session: "session", offset: 100_000, duration: 100_000, state: "stopped", finished: true)
        await store.flush()
        XCTAssertEqual(store.record(for: job())?.watched, true)
        XCTAssertEqual(store.record(for: job())?.offset, 0)
        XCTAssertEqual(update?.kind, "timeline")
        XCTAssertEqual(update?.offset, 100_000)
        XCTAssertEqual(store.pendingCount, 1)
    }
    func testManualWatchedAndUnwatchedUseExplicitOperations() async {
        var kinds: [String] = []
        let transport = HistoryTransport(read: { _, _ in self.remote() }, send: { _, update, _ in kinds.append(update.kind) })
        let store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.mark(remote(), server: server, watched: true); await store.flush()
        store.mark(remote(), server: server, watched: false); await store.flush()
        XCTAssertEqual(kinds, ["watched", "unwatched"])
        XCTAssertEqual(store.record(for: job())?.watched, false)
    }
    func testMultipartKeepsLocalResumeWithoutSendingWrongWholeMoviePosition() async {
        let store = PlaybackHistory(fileURL: location(), serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.recordPlayback(job: job(multipart: true), session: "session", offset: 15_000, duration: 100_000, state: "paused")
        XCTAssertEqual(store.record(for: job(multipart: true))?.offset, 15_000)
        XCTAssertEqual(store.pendingCount, 0)
    }
    func testOnlineStopClosesTheLiveSessionWithoutOfflineFlag() async {
        var sent: WatchUpdate?
        let transport = HistoryTransport(read: { _, _ in XCTFail("A live stop should not need conflict resolution"); return self.remote() }, send: { _, update, _ in sent = update })
        let store = PlaybackHistory(fileURL: location(), transport: transport, serverProvider: { _ in self.server }, monitorNetwork: false, automaticSync: false)
        store.beginSession("live-session")
        store.recordPlayback(job: job(), session: "live-session", offset: 30_000, duration: 100_000, state: "stopped")
        await store.flush()
        XCTAssertEqual(sent?.offline, false)
        XCTAssertEqual(sent?.state, "stopped")
        XCTAssertEqual(sent?.sessionID, "live-session")
    }
}
