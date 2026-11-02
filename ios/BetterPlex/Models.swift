import Foundation
import Security
import CryptoKit

struct PlexEnvelope: Decodable { let MediaContainer: PlexContainer }
struct PlexContainer: Decodable {
    var Metadata: [MediaItem]?
    var Directory: [LibrarySection]?
    var totalSize: Int?
    var offset: Int?
    var machineIdentifier: String?
    var friendlyName: String?
}
struct LibrarySection: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String
    var id: String { key }
}
struct MediaItem: Codable, Identifiable, Hashable {
    let ratingKey: String
    let title: String
    let type: String
    var summary: String?
    var year: Int?
    var thumb: String?
    var parentThumb: String?
    var grandparentThumb: String?
    var grandparentTitle: String?
    var parentTitle: String?
    var index: Int?
    var parentIndex: Int?
    var leafCount: Int?
    var duration: Int?
    var viewOffset: Int?
    var viewCount: Int?
    var lastViewedAt: Double?
    var Media: [MediaVersion]?
    var id: String { ratingKey }
    var isContainer: Bool { type == "show" || type == "season" }
    var artwork: String? { thumb ?? parentThumb ?? grandparentThumb }
    var subtitle: String {
        if type == "episode" { return String(format: "S%02d · E%02d", parentIndex ?? 0, index ?? 0) }
        if let leafCount { return "\(leafCount) episodes" }
        return [year.map(String.init), duration.map { "\($0 / 60_000) min" }].compactMap { $0 }.joined(separator: " · ")
    }
    var downloadTitle: String {
        type == "episode" ? "\(grandparentTitle ?? parentTitle ?? "TV") — \(subtitle) — \(title)" : title
    }
}
struct MediaVersion: Codable, Hashable {
    var duration: Int?
    var videoResolution: String?
    var container: String?
    var videoCodec: String?
    var Part: [MediaPart]?
    var label: String {
        [videoResolution.map { $0 == "4k" ? "4K" : "\($0)p" }, container?.uppercased(), videoCodec?.uppercased(), bytes > 0 ? byteString(bytes) : nil].compactMap { $0 }.joined(separator: " · ")
    }
    var bytes: Int64 { (Part ?? []).reduce(0) { $0 + ($1.size ?? 0) } }
}
struct MediaPart: Codable, Hashable {
    var duration: Int?
    var key: String
    var size: Int64?
    var container: String?
    var file: String?
}
struct PendingSignIn: Codable { let id: Int; let code: String; let expiresAt: Date }
struct PlexPin: Decodable { let id: Int; let code: String; var authToken: String?; var expiresIn: Int? }
struct PlexResource: Decodable, Identifiable {
    var name: String
    var clientIdentifier: String
    var provides: String
    var accessToken: String?
    var connections: [PlexConnection]
    var id: String { clientIdentifier }
}
struct PlexConnection: Decodable { var uri: String; var local: Bool?; var relay: Bool? }
struct PlexUser: Decodable { let id: Int }
struct ServerSession: Codable, Equatable {
    var id: String
    var name: String
    var url: URL
    var token: String
    var userID: String?
    var historyOwner: String {
        userID.map { "plex-user-" + $0 } ?? "connection-" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum PlexError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    static func status(_ code: Int) -> PlexError {
        switch code {
        case 401: return .message("Your Plex session expired. Reconnect in Account.")
        case 403: return .message("This Plex server does not allow this download. Ask its owner to enable downloads for your account.")
        case 404: return .message("This item is no longer available on the server.")
        default: return .message("Plex returned an error (\(code)). Try again when the server is available.")
        }
    }
}
func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

enum SecureStore {
    static let service = "better-plex"
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func write(_ data: Data?, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        guard let data else { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw PlexError.message("Could not securely save your connection (\(status)).") }
    }
}
