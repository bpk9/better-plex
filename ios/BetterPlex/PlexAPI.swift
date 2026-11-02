import SwiftUI
import UIKit

struct PlexAPI {
    static let clientID: String = {
        if let value = UserDefaults.standard.string(forKey: "clientID") { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "clientID")
        return value
    }()
    static func request(_ url: URL, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("better-plex", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("1.1", forHTTPHeaderField: "X-Plex-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(clientID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }
    static func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PlexError.message("Invalid server response.") }
        guard (200..<300).contains(response.statusCode) else { throw PlexError.status(response.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    // Only attach a server token to paths belonging to that server.
    static func url(_ path: String, server: ServerSession, query: [URLQueryItem] = []) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), var components = URLComponents(url: server.url, resolvingAgainstBaseURL: false) else { throw PlexError.message("Invalid Plex media path.") }
        let relative = URLComponents(string: path)
        components.percentEncodedPath = relative?.percentEncodedPath ?? path
        components.queryItems = (relative?.queryItems ?? []) + query
        guard let url = components.url else { throw PlexError.message("Invalid server address.") }
        return url
    }
    static func container(_ path: String, server: ServerSession, query: [URLQueryItem] = []) async throws -> PlexContainer {
        let envelope: PlexEnvelope = try await fetch(request(try url(path, server: server, query: query), token: server.token))
        return envelope.MediaContainer
    }
    static func items(_ path: String, server: ServerSession, query: [URLQueryItem] = []) async throws -> [MediaItem] {
        var results: [MediaItem] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await container(path, server: server, query: query + [URLQueryItem(name: "X-Plex-Container-Start", value: "\(offset)"), URLQueryItem(name: "X-Plex-Container-Size", value: "200")])
            let batch = page.Metadata ?? []
            results += batch
            guard !batch.isEmpty, let total = page.totalSize, results.count < total else { break }
            let next = (page.offset ?? offset) + batch.count
            guard next > offset else { throw PlexError.message("The server returned an invalid library page.") }
            offset = next
        }
        return results
    }
    static func metadata(_ item: MediaItem, server: ServerSession) async throws -> MediaItem {
        guard let value = try await items("/library/metadata/\(item.id)", server: server).first else { throw PlexError.message("This item has no downloadable media.") }
        return value
    }
}

@MainActor final class LibraryStore: ObservableObject {
    @Published var server: ServerSession?
    @Published var resources: [PlexResource] = []
    @Published var sections: [LibrarySection] = []
    @Published var busy = false
    @Published var error: String?
    @Published var authURL: URL?
    @Published var signingIn = false
    private var loginTask: Task<Void, Never>?
    private var loginGeneration = UUID()
    private var pendingSignIn: PendingSignIn?
    private static var authBase: URL {
        #if targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["PLEX_AUTH_TEST_URL"], let url = URL(string: value) { return url }
        #endif
        return URL(string: "https://plex.tv/api/v2")!
    }
    private static func browserURL(for pending: PendingSignIn) -> URL {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "clientID", value: PlexAPI.clientID), URLQueryItem(name: "code", value: pending.code), URLQueryItem(name: "context[device][product]", value: "better-plex")]
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PLEX_AUTH_TEST_URL"] != nil {
            return URL(string: authBase.appendingPathComponent("auth").absoluteString + "?" + (query.percentEncodedQuery ?? ""))!
        }
        #endif
        return URL(string: "https://app.plex.tv/auth#?" + (query.percentEncodedQuery ?? ""))!
    }
    private(set) var accountToken: String?
    var connected: Bool { server != nil }
    init() {
        if let data = SecureStore.read("pendingSignIn"), let pending = try? JSONDecoder().decode(PendingSignIn.self, from: data) {
            if pending.expiresAt > Date() {
                pendingSignIn = pending; authURL = Self.browserURL(for: pending); signingIn = true
            } else { try? SecureStore.write(nil, key: "pendingSignIn") }
        }
        if let data = SecureStore.read("account") { accountToken = String(data: data, encoding: .utf8) }
        if let data = SecureStore.read("selectedServer") { server = try? JSONDecoder().decode(ServerSession.self, from: data) }
        #if targetEnvironment(simulator)
        if let address = ProcessInfo.processInfo.environment["PLEX_TEST_URL"], let url = URL(string: address) {
            server = ServerSession(id: "test-server", name: "Screening Room", url: url, token: "fixture-token", userID: "fixture-user")
            accountToken = nil
        }
        if ProcessInfo.processInfo.arguments.contains("--signed-out") { server = nil; accountToken = nil }
        #endif
    }
    func reloadSections() async {
        guard var server else { return }
        if server.userID == nil, let identity = await resolveUserID(token: accountToken ?? server.token) {
            // Upgrade existing installations without changing their saved connection.
            guard self.server?.token == server.token else { return }
            server.userID = identity
            self.server = server
            try? SecureStore.write(JSONEncoder().encode(server), key: "selectedServer")
            try? SecureStore.write(JSONEncoder().encode(server), key: "server-\(server.id)")
        }
        busy = true; error = nil
        defer { busy = false }
        do { sections = try await PlexAPI.container("/library/sections", server: server).Directory?.filter { ["movie", "show"].contains($0.type) } ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func startSignIn() {
        cancelSignIn()
        signingIn = true; error = nil
        let generation = loginGeneration
        loginTask = Task {
            do {
                var request = PlexAPI.request(Self.authBase.appendingPathComponent("pins"))
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("strong=true".utf8)
                let pin: PlexPin = try await PlexAPI.fetch(request)
                try Task.checkCancellation()
                guard generation == loginGeneration else { return }
                let pending = PendingSignIn(id: pin.id, code: pin.code, expiresAt: Date().addingTimeInterval(TimeInterval(pin.expiresIn ?? 300)))
                try SecureStore.write(JSONEncoder().encode(pending), key: "pendingSignIn")
                pendingSignIn = pending; authURL = Self.browserURL(for: pending)
                await openSignInBrowser()
                guard generation == loginGeneration else { return }
                await pollSignIn(pending, generation: generation)
            } catch {
                guard generation == loginGeneration, !Task.isCancelled else { return }
                signingIn = pendingSignIn != nil
                self.error = error.localizedDescription
            }
        }
    }
    func openSignInBrowser() async {
        guard let authURL else { return }
        let opened = await UIApplication.shared.open(authURL, options: [:])
        if !opened { error = "Could not open your browser. Try Open sign-in browser again." }
    }
    // The app may be suspended or terminated while Google/Plex is open in the browser.
    // Keep the pending PIN in Keychain and check immediately whenever the app returns.
    func resumeSignIn() {
        guard let pending = pendingSignIn else { return }
        loginTask?.cancel()
        loginGeneration = UUID()
        let generation = loginGeneration
        signingIn = true; error = nil
        loginTask = Task { await pollSignIn(pending, generation: generation) }
    }
    private func pollSignIn(_ pending: PendingSignIn, generation: UUID) async {
        do {
            while !Task.isCancelled && generation == loginGeneration {
                guard Date() < pending.expiresAt else {
                    cancelSignIn()
                    error = "Sign-in expired. Tap Sign in with Plex to try again."
                    return
                }
                if UIApplication.shared.applicationState == .active {
                    var components = URLComponents(url: Self.authBase.appendingPathComponent("pins/\(pending.id)"), resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "code", value: pending.code)]
                    let checked: PlexPin = try await PlexAPI.fetch(PlexAPI.request(components.url!))
                    try Task.checkCancellation()
                    guard generation == loginGeneration else { return }
                    if let token = checked.authToken, !token.isEmpty {
                        try SecureStore.write(Data(token.utf8), key: "account")
                        accountToken = token
                        pendingSignIn = nil; authURL = nil; signingIn = false; error = nil
                        try? SecureStore.write(nil, key: "pendingSignIn")
                        await discover()
                        return
                    }
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            guard generation == loginGeneration, !Task.isCancelled else { return }
            // Preserve the PIN after a temporary network failure so a return/retry can finish it.
            self.error = "Could not check Plex sign-in. Check your connection, then tap Check sign-in."
        }
    }
    func cancelSignIn() {
        loginGeneration = UUID()
        loginTask?.cancel(); loginTask = nil
        pendingSignIn = nil; authURL = nil; signingIn = false
        try? SecureStore.write(nil, key: "pendingSignIn")
    }
    private func resolveUserID(token: String) async -> String? {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PLEX_TEST_URL"] != nil { return "fixture-user" }
        #endif
        var request = PlexAPI.request(Self.authBase.appendingPathComponent("user"), token: token)
        request.timeoutInterval = 3
        guard let user: PlexUser = try? await PlexAPI.fetch(request) else { return nil }
        return String(user.id)
    }
    func discover() async {
        guard let accountToken else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let values: [PlexResource] = try await PlexAPI.fetch(PlexAPI.request(URL(string: Self.authBase.appendingPathComponent("resources").absoluteString + "?includeHttps=1&includeRelay=1&includeIPv6=1")!, token: accountToken))
            guard self.accountToken == accountToken else { return }
            resources = values.filter { $0.provides.split(separator: ",").contains("server") }
            if resources.isEmpty { error = "No Plex servers are available to this account." }
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ resource: PlexResource) async {
        busy = true; error = nil
        defer { busy = false }
        let connections = resource.connections.sorted {
            func rank(_ c: PlexConnection) -> Int { (c.relay == true ? 10 : 0) + (c.uri.hasPrefix("https:") ? 0 : 4) + (c.local == true ? 0 : 1) }
            return rank($0) < rank($1)
        }
        let userID = await resolveUserID(token: accountToken ?? resource.accessToken ?? "")
        for connection in connections {
            guard let url = URL(string: connection.uri), ["https", "http"].contains(url.scheme) else { continue }
            let candidate = ServerSession(id: resource.id, name: resource.name, url: url, token: resource.accessToken ?? accountToken ?? "", userID: userID)
            do {
                let sections = try await PlexAPI.container("/library/sections", server: candidate)
                try select(candidate, sections: sections.Directory ?? [])
                return
            } catch { continue }
        }
        error = "Could not reach \(resource.name). Check that Plex is running and that you are on its network, VPN, or have remote access enabled."
    }
    func connectManually(address: String, token: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/", !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlexError.message("Enter a server address such as http://192.168.1.10:32400 and a Plex token.") }
            var candidate = ServerSession(id: url.absoluteString, name: "My Plex", url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let info = try await PlexAPI.container("/", server: candidate)
            candidate.userID = await resolveUserID(token: candidate.token)
            candidate.id = info.machineIdentifier ?? candidate.id
            candidate.name = info.friendlyName ?? candidate.name
            let sections = try await PlexAPI.container("/library/sections", server: candidate)
            try select(candidate, sections: sections.Directory ?? [])
        } catch { self.error = error.localizedDescription }
    }
    private func select(_ value: ServerSession, sections: [LibrarySection]) throws {
        try SecureStore.write(JSONEncoder().encode(value), key: "selectedServer")
        try SecureStore.write(JSONEncoder().encode(value), key: "server-\(value.id)")
        server = value
        PlaybackHistory.shared.sync()
        self.sections = sections.filter { ["movie", "show"].contains($0.type) }
    }
    func disconnect() {
        cancelSignIn()
        PlaybackHistory.shared.cancelSync()
        Downloads.shared.pauseAll(forgetResumeData: true)
        SecureStore.clear()
        accountToken = nil; server = nil; sections = []; resources = []; error = nil
    }
}
