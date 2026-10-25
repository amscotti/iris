import Foundation

/// Serializes persistence and recovery. An unreadable load latches writes off;
/// only a successful retry or explicit, backed-up recovery can enable them.
public final class SettingsRepository: @unchecked Sendable {
    public static let backupKey = "iris.appSettings.unreadableBackup"
    public static let currentVersion = AppSettings.currentSchemaVersion

    private let persistence: any PersistenceProviding
    private let registry: ProviderRegistry
    private let defaults: AppSettings
    private let lock = NSLock()
    private var state: Access = .unloaded
    /// True while the loaded payload was left unstamped because migration
    /// is deferred (legacy per-prompt choices but no rewriter descriptors).
    /// Saves then stay unstamped and keep the raw prompt entries, so a
    /// later descriptor-bearing load can still migrate them.
    private var migrationDeferred = false
    private var deferredRaw: Data?
    private var deferredSchemaVersion = 1

    private enum Access {
        case unloaded
        case writable
        case blocked(raw: Data?)
    }

    public enum RepositoryError: Error, LocalizedError {
        case recoveryRequired
        case retryReadRequired

        public var errorDescription: String? {
            switch self {
            case .recoveryRequired: return "Stored settings need recovery before changes can be saved."
            case .retryReadRequired: return "Retry reading settings before replacing them; no backup could be read."
            }
        }
    }

    public enum LoadOutcome: Sendable {
        case missing(AppSettings)
        case loaded(AppSettings)
        case unsupportedVersion(found: Int, raw: Data)
        case corrupt(raw: Data, message: String)
        case unavailable(message: String)
    }

    /// A persistence read failure whose damaged value was serialized so a
    /// backed-up recovery can retain a secret-safe representation of it.
    public protocol DamagedPayloadPreserving: Error {
        var preservedPayload: Data? { get }
    }

    /// The `.defaults` fallback preserves legacy behavior for portable and test
    /// callers only. Application composition must inject its current settings
    /// defaults explicitly; the fallback does not define application policy.
    public init(
        persistence: any PersistenceProviding, registry: ProviderRegistry = ProviderRegistry(),
        defaults: AppSettings = .defaults
    ) {
        self.persistence = persistence
        self.registry = registry
        self.defaults = defaults
    }

    public var canRecover: Bool {
        lock.withLock {
            if case .blocked(.some) = state { return true }
            return false
        }
    }

    public func load() -> LoadOutcome { lock.withLock { loadLocked() } }

    private func loadLocked() -> LoadOutcome {
        // Best-effort security migration for recovery backups written by
        // versions that preserved payloads before secret redaction existed.
        _ = try? retroRedactedBackupsLocked()
        migrationDeferred = false
        deferredRaw = nil
        deferredSchemaVersion = 1
        let raw: Data?
        do {
            raw = try persistence.load(key: AppSettings.storageKey)
        } catch let damage as DamagedPayloadPreserving {
            state = .blocked(raw: damage.preservedPayload)
            return .unavailable(
                message: (damage as? LocalizedError)?.errorDescription
                    ?? "The stored settings value is damaged.")
        } catch {
            state = .blocked(raw: nil)
            return .unavailable(message: error.localizedDescription)
        }
        guard let data = raw else {
            state = .writable
            return .missing(defaults)
        }
        state = .blocked(raw: data)
        if let found = Self.peekSchemaVersion(data), found > Self.currentVersion {
            return .unsupportedVersion(found: found, raw: data)
        }
        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            migrationDeferred = SettingsMigrations.apply(to: &settings, raw: data, registry: registry)
            deferredRaw = migrationDeferred ? data : nil
            deferredSchemaVersion = settings.schemaVersion
            state = .writable
            return .loaded(settings)
        } catch {
            return .corrupt(raw: data, message: error.localizedDescription)
        }
    }

    public func save(_ settings: AppSettings) throws {
        try lock.withLock {
            if case .unloaded = state { _ = loadLocked() }
            guard case .writable = state else { throw RepositoryError.recoveryRequired }
            try saveLocked(settings)
        }
    }

    /// The caller explicitly chose a fresh configuration. Back up a safely
    /// redacted representation, including an empty payload, before any overwrite.
    public func recoverUsingDefaults() throws -> AppSettings {
        try lock.withLock {
            guard case .blocked(let raw) = state else { throw RepositoryError.recoveryRequired }
            guard let raw else { throw RepositoryError.retryReadRequired }
            try preserveLocked(raw)
            try saveLocked(defaults)
            state = .writable
            return defaults
        }
    }

    public func preserveUnreadable(_ raw: Data) throws {
        try lock.withLock { try preserveLocked(raw) }
    }

    /// Backups written before secret redaction existed may still contain
    /// plaintext secrets. Rewrite every existing slot through the current
    /// fail-closed redaction policy without changing backup ordering.
    private func retroRedactedBackupsLocked() throws -> (backups: [Data], nextSlot: Int) {
        var backups: [Data] = []
        var key = Self.backupKey
        var index = 1
        while true {
            let existing: Data?
            do {
                existing = try persistence.load(key: key)
            } catch let damage as DamagedPayloadPreserving {
                // A damaged backup slot must not permanently block recovery
                // of the main payload. Preserve only a safely redacted form
                // of the damaged value, then continue to the next slot.
                if let preserved = damage.preservedPayload {
                    let redacted = Self.redactingSecrets(from: preserved, registry: registry)
                    try persistence.save(redacted, forKey: key)
                    backups.append(redacted)
                }
                index += 1
                key = "\(Self.backupKey).\(index)"
                continue
            }
            guard let existing else { break }
            let redacted = Self.redactingSecrets(from: existing, registry: registry)
            if redacted != existing {
                try persistence.save(redacted, forKey: key)
            }
            backups.append(redacted)
            index += 1
            key = "\(Self.backupKey).\(index)"
        }
        return (backups, index)
    }

    private func preserveLocked(_ raw: Data) throws {
        let redacted = Self.redactingSecrets(from: raw, registry: registry)
        let scanned = try retroRedactedBackupsLocked()
        if scanned.backups.contains(redacted) { return }
        // Never destroy the earliest recovery backup to preserve a newer
        // one: overflow goes to deterministic `backupKey.N` slots so every
        // recovery stays discoverable via `loadAllUnreadableBackups()`.
        // The next slot is tracked independently of the readable array:
        // damaged slots still occupy their position.
        let key = scanned.backups.isEmpty ? Self.backupKey : "\(Self.backupKey).\(scanned.nextSlot)"
        try persistence.save(redacted, forKey: key)
    }

    public func loadUnreadableBackup() throws -> Data? {
        try lock.withLock { try retroRedactedBackupsLocked().backups.first }
    }

    /// Every secret-safe recovery backup in recovery order: the base-key
    /// backup first, then `backupKey.2`, `backupKey.3`, … until the first
    /// gap. Earlier recoveries are never overwritten, so all of them —
    /// not just the first — stay retrievable.
    public func loadAllUnreadableBackups() throws -> [Data] {
        try lock.withLock { try retroRedactedBackupsLocked().backups }
    }

    /// Raw stored payload for `AppSettings.storageKey`, if any. Lets callers
    /// decide whether a re-read actually needs a version-stamping rewrite
    /// without going through a full decode.
    public func rawPayload() throws -> Data? {
        try lock.withLock { try persistence.load(key: AppSettings.storageKey) }
    }

    private func saveLocked(_ settings: AppSettings) throws {
        var versioned = settings
        versioned.schemaVersion = migrationDeferred ? deferredSchemaVersion : Self.currentVersion
        let encoded = try JSONEncoder().encode(versioned)
        try persistence.save(
            migrationDeferred ? Self.restoringLegacyPromptFields(encoded, from: deferredRaw) : encoded,
            forKey: AppSettings.storageKey)
    }

    /// A deferred-migration save re-encodes decoded prompts, which drops
    /// the legacy per-prompt `model`/`effort` choices that live only in the
    /// raw payload. Merge exactly those two keys back into each prompt that
    /// survives the edit — the freshly encoded modern fields always win, so
    /// edits are not reverted, and a later descriptor-bearing load can
    /// still migrate the preserved choices. Other legacy keys (notably the
    /// pre-selection `enabled` toggle) are dropped: after any save the
    /// selection is explicit, and a preserved `enabled` would resurrect a
    /// prompt the person deliberately set to None.
    static func restoringLegacyPromptFields(_ encoded: Data, from raw: Data?) -> Data {
        guard let raw,
            let storedObject = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
            let storedPrompts = storedObject["prompts"] as? [[String: Any]],
            var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
            let prompts = object["prompts"] as? [[String: Any]]
        else { return encoded }
        let legacyKeys: Set<String> = ["model", "effort"]
        var byID: [String: [String: Any]] = [:]
        for prompt in storedPrompts {
            // UUIDs are case-insensitive; JSON encoders and hand-edited
            // payloads may differ in case.
            guard let id = (prompt["id"] as? String)?.lowercased(), byID[id] == nil else { continue }
            byID[id] = prompt
        }
        object["prompts"] = prompts.map { prompt in
            guard let id = (prompt["id"] as? String)?.lowercased(),
                let stored = byID[id]
            else { return prompt }
            var merged = prompt
            for (key, value) in stored where legacyKeys.contains(key) && merged[key] == nil {
                merged[key] = value
            }
            return merged
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? encoded
    }

    public static func peekSchemaVersion(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schemaVersion"] as? Int
    }
}
