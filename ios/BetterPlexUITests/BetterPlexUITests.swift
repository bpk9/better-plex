import XCTest

final class BetterPlexUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testPlaybackHistoryRoundTrip() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PLEX_TEST_URL"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["media-105"].waitForExistence(timeout: 10))
        app.buttons["media-105"].tap()
        XCTAssertTrue(app.buttons["download-selection"].waitForExistence(timeout: 10))
        app.buttons["download-selection"].tap()
        app.buttons["confirm-download"].tap()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["play-105"].waitForExistence(timeout: 30))
        app.buttons["play-105"].tap()
        XCTAssertTrue(app.staticTexts["player-resume-position"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["player-resume-position"].label, "Resumed at 0:12")
        let played = expectation(description: "Allow actual media to advance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { played.fulfill() }
        wait(for: [played], timeout: 5)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["history-105"].waitForExistence(timeout: 10))
        let online = try fixtureJSON("/test/history") as! [[String: Any]]
        XCTAssertTrue(online.contains { $0["ratingKey"] as? String == "105" && Int($0["time"] as? String ?? "0")! >= 12000 })
        _ = try fixtureJSON("/test/offline?enabled=1", method: "POST")
        defer { _ = try? fixtureJSON("/test/offline?enabled=0", method: "POST") }
        app.buttons["play-105"].tap()
        XCTAssertTrue(app.staticTexts["player-resume-position"].waitForExistence(timeout: 10))
        let offlinePlayed = expectation(description: "Advance offline media")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { offlinePlayed.fulfill() }
        wait(for: [offlinePlayed], timeout: 5)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["history-105"].label.contains("Sync pending"))
        app.terminate(); app.launch()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["history-105"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["history-105"].label.contains("Sync pending"))
        _ = try fixtureJSON("/test/offline?enabled=0", method: "POST")
        app.tabBars.buttons["Account"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["Sync playback history now"].waitForExistence(timeout: 10))
        app.buttons["Sync playback history now"].tap()
        XCTAssertTrue(app.staticTexts["Playback sync is up to date"].waitForExistence(timeout: 15))
        let updates = try fixtureJSON("/test/history") as! [[String: Any]]
        XCTAssertTrue(updates.contains { $0["ratingKey"] as? String == "105" && $0["offline"] as? String == "1" && $0["state"] as? String == "stopped" })
    }
    private func fixtureJSON(_ path: String, method: String = "GET") throws -> Any {
        let done = expectation(description: "Fixture request")
        var output: Data?
        var failure: Error?
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765" + path)!)
        request.httpMethod = method
        URLSession.shared.dataTask(with: request) { data, _, error in
            output = data; failure = error; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return try JSONSerialization.jsonObject(with: XCTUnwrap(output))
    }
    func testBrowserSignInSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--signed-out"]
        app.launchEnvironment["PLEX_AUTH_TEST_URL"] = "http://127.0.0.1:18766"
        app.launch()
        app.tabBars.buttons["Account"].tap()
        if app.buttons["Cancel sign-in"].exists { app.buttons["Cancel sign-in"].tap() }
        app.buttons["plex-sign-in"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        // First-run Safari may show its introductory sheet on a fresh simulator.
        if safari.buttons["Continue"].waitForExistence(timeout: 2) { safari.buttons["Continue"].tap() }
        XCTAssertTrue(safari.staticTexts["Plex browser test"].waitForExistence(timeout: 15))
        app.activate()
        XCTAssertTrue(app.buttons["reopen-sign-in"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["reopen-sign-in"].waitForExistence(timeout: 10))
        app.buttons["reopen-sign-in"].tap()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        let field = safari.textFields["Test email"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("test@example.com")
        safari.buttons["Authorize test account"].tap()
        XCTAssertTrue(safari.staticTexts["Test sign-in complete"].waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(app.buttons["Browser Test Server"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["reopen-sign-in"].exists)
        XCTAssertTrue(app.buttons["Refresh servers"].exists)
    }
    func testCancelledBrowserSignInStaysCancelled() {
        let app = XCUIApplication()
        app.launchArguments = ["--signed-out"]
        app.launchEnvironment["PLEX_AUTH_TEST_URL"] = "http://127.0.0.1:18766"
        app.launch()
        app.tabBars.buttons["Account"].tap()
        app.buttons["plex-sign-in"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(safari.buttons["Authorize test account"].waitForExistence(timeout: 15))
        app.activate()
        app.buttons["Cancel sign-in"].tap()
        safari.activate()
        safari.buttons["Authorize test account"].tap()
        app.activate()
        XCTAssertTrue(app.buttons["plex-sign-in"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Browser Test Server"].exists)
        XCTAssertFalse(app.buttons["reopen-sign-in"].exists)
        app.terminate(); app.launch()
        app.tabBars.buttons["Account"].tap()
        XCTAssertFalse(app.buttons["reopen-sign-in"].exists)
    }
    func testSignedOutAndOfflineTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--signed-out"]
        app.launch()
        XCTAssertTrue(app.buttons["Connect to Plex"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["plex-sign-in"].exists)
        app.buttons["Connect manually"].tap()
        XCTAssertTrue(app.textFields["server-url"].exists)
    }
    func testBrowseAndDownloadMovieAndSeason() {
        let app = XCUIApplication()
        app.launchEnvironment["PLEX_TEST_URL"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["section-1"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["media-101"].waitForExistence(timeout: 10))
        app.buttons["media-101"].tap()
        XCTAssertTrue(app.buttons["download-selection"].waitForExistence(timeout: 10))
        app.buttons["download-selection"].tap()
        XCTAssertTrue(app.buttons["confirm-download"].waitForExistence(timeout: 5))
        app.buttons["confirm-download"].tap()
        XCTAssertTrue(app.staticTexts["queued-notice"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["play-101"].waitForExistence(timeout: 30))
        app.buttons["play-101"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["offline-player"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["play-101"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Library"].tap()
        app.buttons["section-2"].tap()
        XCTAssertTrue(app.buttons["media-201"].waitForExistence(timeout: 10))
        app.buttons["media-201"].tap()
        XCTAssertTrue(app.buttons["media-202"].waitForExistence(timeout: 10))
        app.buttons["media-202"].tap()
        XCTAssertTrue(app.buttons["download-selection"].waitForExistence(timeout: 10))
        app.buttons["download-selection"].tap()
        XCTAssertTrue(app.buttons["confirm-download"].waitForExistence(timeout: 10))
        app.buttons["confirm-download"].tap()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["play-203"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["play-204"].waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Downloaded season and movie"; shot.lifetime = .keepAlways; add(shot)
    }
    func testPauseResumeAndPermissionFailure() {
        let app = XCUIApplication()
        app.launchEnvironment["PLEX_TEST_URL"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["media-103"].waitForExistence(timeout: 10))
        app.buttons["media-103"].tap()
        XCTAssertTrue(app.buttons["download-selection"].waitForExistence(timeout: 10))
        app.buttons["download-selection"].tap()
        app.buttons["confirm-download"].tap()
        app.tabBars.buttons["Downloads"].tap()
        app.buttons["In progress"].tap()
        XCTAssertTrue(app.buttons["pause-103"].waitForExistence(timeout: 5))
        app.buttons["pause-103"].tap()
        XCTAssertTrue(app.buttons["resume-103"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["Downloads"].tap()
        app.buttons["In progress"].tap()
        XCTAssertTrue(app.buttons["resume-103"].waitForExistence(timeout: 10))
        app.buttons["resume-103"].tap()
        app.buttons["Saved"].tap()
        XCTAssertTrue(app.buttons["play-103"].waitForExistence(timeout: 40))
        app.tabBars.buttons["Library"].tap()
        app.buttons["media-102"].tap()
        XCTAssertTrue(app.buttons["download-selection"].waitForExistence(timeout: 10))
        app.buttons["download-selection"].tap()
        app.buttons["confirm-download"].tap()
        app.tabBars.buttons["Downloads"].tap()
        app.buttons["In progress"].tap()
        XCTAssertTrue(app.buttons["resume-102"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["This Plex server does not allow this download. Ask its owner to enable downloads for your account."].exists)
        XCTAssertFalse(app.buttons["play-102"].exists)
    }
    func testZDisconnectKeepsOfflineFiles() {
        let app = XCUIApplication()
        app.launchEnvironment["PLEX_TEST_URL"] = "http://127.0.0.1:18765"
        app.launch()
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: 10))
        app.buttons["Disconnect"].tap()
        app.alerts.buttons["Disconnect"].tap()
        XCTAssertFalse(app.buttons["Disconnect"].exists)
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Connect to Plex"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["play-101"].waitForExistence(timeout: 10))
        app.buttons["play-101"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-player"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
    }
}
