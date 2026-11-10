import Foundation
import MozillaAppServices
import Security

/// Saved passwords in Mozilla's logins database; the Sync "passwords" engine shares them with Zen.
/// The database is encrypted with a key kept in this iPhone's Keychain. Calls block on SQLite and
/// crypto, so callers stay off the main actor.
final class PasswordStore: @unchecked Sendable {
    static let shared = try? PasswordStore()

    /// The Sync engine's name, as Firefox Sync knows it.
    static let engine = "passwords"

    private let store: LoginStore

    private init() throws {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let path = dir.appendingPathComponent("logins.db").path
        let key: String
        if let saved = try Keychain.read() {
            key = saved
        } else {
            // Without its key an old database can't be read; Sync restores the passwords into a new one.
            try? FileManager.default.removeItem(atPath: path)
            key = try createKey()
            guard Keychain.save(key) else { throw StoreError.keychain }
        }
        store = createLoginStoreWithStaticKeyManager(path: path, key: key)
        store.registerWithSyncManager()
    }

    func all() -> [Login] {
        ((try? store.list()) ?? []).sorted { Self.host($0.origin) < Self.host($1.origin) }
    }

    /// Logins saved for exactly this origin ("https://example.com"), most used first.
    func logins(for origin: String) -> [Login] {
        let all = (try? store.list()) ?? []
        return all.filter { $0.origin == origin }.sorted { $0.timeLastUsed > $1.timeLastUsed }
    }

    func wipeLocal() {
        try? store.wipeLocal()
    }

    func touch(_ login: Login) {
        try? store.touch(id: login.id)
    }

    @discardableResult
    func add(origin: String, formActionOrigin: String?, username: String, password: String) -> Bool {
        let entry = LoginEntry(origin: origin, httpRealm: nil, formActionOrigin: formActionOrigin ?? origin,
                               usernameField: "", passwordField: "", password: password, username: username)
        return (try? store.add(login: entry)) != nil
    }

    @discardableResult
    func updatePassword(_ login: Login, to password: String) -> Bool {
        let entry = LoginEntry(origin: login.origin, httpRealm: login.httpRealm,
                               formActionOrigin: login.formActionOrigin, usernameField: login.usernameField,
                               passwordField: login.passwordField, password: password, username: login.username)
        return (try? store.update(id: login.id, login: entry)) != nil
    }

    func delete(_ login: Login) {
        _ = try? store.delete(id: login.id)
    }

    /// "https://accounts.example.com" -> "accounts.example.com".
    static func host(_ origin: String) -> String {
        URL(string: origin)?.host() ?? origin
    }

    enum StoreError: Error {
        case keychain
    }

    /// The database key, readable only on this device after its first unlock.
    private enum Keychain {
        private static let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // The app's first name; renaming the service would lose the key to the saved database.
            kSecAttrService as String: "dev.khvoynitsky.ZenTabs.logins",
            kSecAttrAccount as String: "database-key",
        ]

        /// Nil only when there is no key. Any other failure throws: treated as missing, it deleted the database.
        static func read() throws -> String? {
            var request = query
            request[kSecReturnData as String] = true
            var result: AnyObject?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else { throw StoreError.keychain }
            return key
        }

        static func save(_ key: String) -> Bool {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemDelete(query as CFDictionary)
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
    }
}
