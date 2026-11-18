import Foundation
import Security

/// Profile secrets in ~/Library/Application Support/Sonar/secrets.json (0600).
/// Not in the Keychain: ad-hoc signed builds get a new identity each release, so the Keychain kept asking for the
/// login password. Secrets saved by older versions are moved out of the Keychain on first run.
enum SecretStore {
    enum StoreError: LocalizedError {
        case migrationBlocked
        var errorDescription: String? {
            "Sonar couldn't move its saved keys out of the Keychain. Click Allow when macOS asks, then try again."
        }
    }

    /// Overridable in tests.
    static var fileURL: URL = Paths.appSupport.appendingPathComponent("secrets.json")
    private static var cache: [UUID: ProfileSecrets]?

    // MARK: Public API

    static func load(for id: UUID, retry: Bool = false) throws -> ProfileSecrets? {
        try all(retry: retry)[id]
    }

    static func save(_ secrets: ProfileSecrets, for id: UUID) throws {
        var v = try all(retry: true)
        v[id] = secrets
        try write(v)
    }

    static func delete(for id: UUID) {
        guard var v = try? all(retry: false) else { return }
        v[id] = nil
        try? write(v)
    }

    // MARK: File

    private static var migrationDenied = false

    private static func all(retry: Bool) throws -> [UUID: ProfileSecrets] {
        if let c = cache { return c }
        if let data = try? Data(contentsOf: fileURL) {
            let v = (try? JSONDecoder().decode([UUID: ProfileSecrets].self, from: data)) ?? [:]
            cache = v
            return v
        }
        // First run: move secrets from the Keychain (older versions).
        if migrationDenied && !retry { throw StoreError.migrationBlocked }
        #if DEBUG
        if skipLegacyMigration { try write([:]); return [:] }
        #endif
        switch LegacyKeychain.readAll() {
        case .ok(let v):
            try write(v)
            LegacyKeychain.deleteAll()
            migrationDenied = false
            return v
        case .denied:
            migrationDenied = true
            throw StoreError.migrationBlocked
        }
    }

    private static func write(_ v: [UUID: ProfileSecrets]) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONEncoder().encode(v)
        let tmp = dir.appendingPathComponent(".secrets.\(UUID().uuidString).tmp")
        // Create as 0600 before writing, then replace atomically.
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            try h.write(contentsOf: data)
            try h.close()
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cache = v
    }

    #if DEBUG
    /// Tests: skip the Keychain.
    static var skipLegacyMigration = false
    static func resetCacheForTesting() { cache = nil; migrationDenied = false }
    #endif
}

/// Secrets stored by older versions in the login Keychain.
private enum LegacyKeychain {
    static let service = "com.g3ntrix.sonar.profile"

    enum Result { case ok([UUID: ProfileSecrets]), denied }

    static func readAll() -> Result {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return .ok([:]) }
        guard st == errSecSuccess, let items = out as? [[String: Any]] else { return .ok([:]) }

        var v: [UUID: ProfileSecrets] = [:]
        for item in items {
            guard let acct = item[kSecAttrAccount as String] as? String else { continue }
            var dq: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var d: CFTypeRef?
            let s = SecItemCopyMatching(dq as CFDictionary, &d)
            if s == errSecUserCanceled || s == errSecAuthFailed || s == errSecInteractionNotAllowed { return .denied }
            dq.removeAll()
            guard s == errSecSuccess, let data = d as? Data else { continue }
            if acct == "vault", let all = try? JSONDecoder().decode([UUID: ProfileSecrets].self, from: data) {
                v.merge(all) { cur, _ in cur }
            } else if let id = UUID(uuidString: acct), let one = try? JSONDecoder().decode(ProfileSecrets.self, from: data) {
                v[id] = v[id] ?? one
            }
        }
        return .ok(v)
    }

    static func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}
