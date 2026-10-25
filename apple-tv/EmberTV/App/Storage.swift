import Foundation
import Security

/// One signed-in person on one server ("profile").
struct Account: Codable, Identifiable, Hashable {
    var serverURL: String
    var serverName: String
    var userId: String
    var name: String
    var token: String
    var isAdmin: Bool
    var imageTag: String?
    var seerrCookie: String?

    var id: String { "\(serverURL)|\(userId)" }
}

/// Saved settings. Sign-in tokens live in the Keychain; everything else in UserDefaults.
enum Storage {
    private static let defaults = UserDefaults.standard
    private static let service = "app.ember.tv"

    static var deviceId: String {
        if let id = defaults.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: "deviceId")
        return id
    }

    static func string(_ key: String) -> String? { defaults.string(forKey: key) }
    static func set(_ value: String?, _ key: String) { defaults.set(value, forKey: key) }
    static func bool(_ key: String, default value: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? value }
    static func set(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }

    // MARK: Accounts (Keychain)

    static func loadAccounts() -> [Account] {
        guard let data = keychainRead("accounts") else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func saveAccounts(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        keychainWrite("accounts", data)
    }

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private static func keychainRead(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainWrite(_ key: String, _ data: Data) {
        let q = query(key)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Streaming quality choices. nil bitrate = best quality (original or remux).
struct QualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let bitrate: Int?

    static let all: [QualityOption] = [
        .init(id: "original", label: "Best · original quality", bitrate: nil),
        .init(id: "20m", label: "1080p · 20 Mbps", bitrate: 20_000_000),
        .init(id: "8m", label: "720p · 8 Mbps", bitrate: 8_000_000),
        .init(id: "4m", label: "720p · 4 Mbps", bitrate: 4_000_000),
        .init(id: "2m", label: "480p · 2 Mbps", bitrate: 2_000_000),
    ]

    static func find(_ id: String) -> QualityOption { all.first { $0.id == id } ?? all[0] }
}
