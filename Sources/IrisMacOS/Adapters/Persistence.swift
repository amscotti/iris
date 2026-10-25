import Foundation
import IrisCore
import Security
import os

/// Plain (non-secret) keyed persistence backed by user defaults.
///
/// Writes are last-writer-wins with no cross-process coordination: settings
/// writes must be serialized through `SettingsRepository` in one process,
/// and `.standard` is shared with UI state (e.g. the selected settings tab)
/// plus previews/tests, so concurrent writers outside the repository can
/// lose provider namespaces.
public struct UserDefaultsPersistence: PersistenceProviding, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(key: String) throws -> Data? {
        guard let object = defaults.object(forKey: key) else { return nil }
        // A present-but-not-Data value (hand-edited or damaged plist) must
        // not read back as "absent": callers would overwrite it without
        // preservation. Serialize the damage so a backed-up recovery can
        // still keep a copy before replacing it.
        guard let data = object as? Data else {
            throw DamagedValueError(key: key, preservedPayload: Self.preservingSerialization(of: object))
        }
        return data
    }

    /// Property-list bytes when the plist layer accepts the object, a
    /// textual description otherwise, so the damaged value stays preservable.
    static func preservingSerialization(of object: Any) -> Data? {
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: object, format: .binary, options: 0)
        {
            return data
        }
        return String(describing: object).data(using: .utf8)
    }

    public func save(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
    }

    public func delete(key: String) throws {
        defaults.removeObject(forKey: key)
    }
}

/// A stored value that is present but not data, so it cannot be decoded or
/// safely replaced. `preserved` carries the damaged value serialized, so
/// recovery can back it up (never as plaintext secrets — the repository
/// redacts preserved bytes) before overwriting it.
public struct DamagedValueError: Error, LocalizedError, Sendable {
    public let key: String
    public let preservedPayload: Data?

    public init(key: String, preservedPayload: Data?) {
        self.key = key
        self.preservedPayload = preservedPayload
    }

    public var errorDescription: String? {
        "The saved value for “\(key)” is damaged."
    }
}

extension DamagedValueError: SettingsRepository.DamagedPayloadPreserving {}

/// Keychain-backed secret storage. Secrets never live in plain persistence.
///
/// Writes are serialized in-process; concurrent saves/deletes from other
/// processes remain last-writer-wins. Items are addressed on the default
/// file-based keychain: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is
/// requested on new items and upgraded on old ones, but on that keychain
/// the accessibility attribute is not enforced (or observable). Enforcing
/// it requires the data-protection keychain (`kSecUseDataProtectionKeychain`
/// on macOS), which in turn requires a `keychain-access-groups` entitlement
/// this app does not carry; adding the flag without the entitlement fails
/// every secret operation with `errSecMissingEntitlement`.
public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    let service: String
    private let writeLock = NSLock()

    public init(service: String = AppIdentity.identifier) {
        self.service = service
    }

    /// SecItem calls are synchronous IPC and most callers are MainActor:
    /// run every operation detached so keychain latency never stalls the UI.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    public func load(key: String) async throws -> String? {
        try await runOffMain { try self.loadSync(key: key) }
    }

    public func save(_ value: String, forKey key: String) async throws {
        try await runOffMain { try self.saveSync(value, forKey: key) }
    }

    public func delete(key: String) async throws {
        try await runOffMain { try self.deleteSync(key: key) }
    }

    private func loadSync(key: String) throws -> String? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError(code: errSecParam, operation: "load")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw KeychainError(code: status, operation: "load")
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(code: errSecDecode, operation: "load")
        }
        return secret
    }

    private func saveSync(_ value: String, forKey key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError(code: errSecParam, operation: "save")
        }
        // The SecretStoring contract: an empty (or whitespace-only) value
        // is a delete, so `load` can treat nil as "missing" without
        // zero-length items lingering.
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = value.data(using: .utf8)
        else {
            try deleteSync(key: key)
            return
        }
        try writeLock.withLock { try self.saveLocked(data, forKey: key) }
    }

    private func saveLocked(_ data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status != errSecItemNotFound else {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // A concurrent saver added the item between our update and
                // add; fall back to updating the winner instead of failing.
                let retryStatus = SecItemUpdate(
                    query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainError(code: retryStatus, operation: "save")
                }
                try upgradeAccessibilityIfNeeded(query: query, data: data)
                return
            }
            guard addStatus == errSecSuccess else {
                throw KeychainError(code: addStatus, operation: "save")
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError(code: status, operation: "save")
        }
        try upgradeAccessibilityIfNeeded(query: query, data: data)
    }

    /// Best-effort hardening: items written by older builds may carry a more
    /// permissive accessibility than new items. After the value is safely
    /// stored, try to upgrade such items in place to
    /// `WhenUnlockedThisDeviceOnly`. The upgrade never deletes: a failed or
    /// rejected in-place update leaves the item untouched (the value was
    /// already written correctly) rather than risking a delete whose re-add
    /// could fail and destroy the secret. On the file-based keychain the
    /// probe below typically reports nothing, so this stays a no-op there.
    private enum AccessibilityProbe {
        case accessible(String)
        case unobservable
        case missing
    }

    private func upgradeAccessibilityIfNeeded(query: [String: Any], data: Data) throws {
        let desired = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        switch currentAccessibility(query: query) {
        case .unobservable:
            return
        case .missing:
            // The item vanished between update and probe (concurrent
            // delete); re-add our value with the hardened accessibility.
            // Add-only: no window where an existing secret is missing.
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(
                    query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainError(code: retryStatus, operation: "save")
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw KeychainError(code: addStatus, operation: "save")
            }
        case .accessible(let current) where current != desired:
            // In-place only. Some OS versions reject accessibility changes via
            // update (and on the default file-based keychain the attribute is
            // not observable at all); leaving the item as-is is safe — the
            // secret value itself was already persisted by the caller.
            let directStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary)
            if directStatus != errSecSuccess {
                Self.logger.notice(
                    "Keychain accessibility upgrade left as-is (status \(directStatus, privacy: .public)).")
            }
        case .accessible:
            return
        }
    }

    private static let logger = Logger(subsystem: AppIdentity.identifier, category: "keychain")

    /// The item's current accessibility attribute, when the keychain
    /// exposes one. On the default file-based keychain this is typically
    /// absent even when the item exists, in which case there is nothing
    /// comparable to upgrade.
    private func currentAccessibility(query: [String: Any]) -> AccessibilityProbe {
        var probe = query
        probe[kSecReturnAttributes as String] = true
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(probe as CFDictionary, &item)
        guard status != errSecItemNotFound else { return .missing }
        guard status == errSecSuccess,
            let attributes = item as? [String: Any],
            let accessible = attributes[kSecAttrAccessible as String] as? String
        else {
            return .unobservable
        }
        return .accessible(accessible)
    }

    private func deleteSync(key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError(code: errSecParam, operation: "delete")
        }
        try writeLock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(code: status, operation: "delete")
            }
        }
    }
}

/// Keychain failures surfaced with the failing operation.
public struct KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: OSStatus
    public var operation: String

    public init(code: OSStatus, operation: String) {
        self.code = code
        self.operation = operation
    }

    public var description: String { "Keychain \(operation) failed (\(code))." }
}
