import Foundation
import IrisCore
import Observation
import os

/// Owns persisted settings, recovery, and the configuration-change boundary.
@MainActor
@Observable
public final class SettingsController {
    public private(set) var settings: AppSettings
    public private(set) var loadIssue: String?
    public private(set) var saveError: String?
    public var onChange: ((Change) -> Void)?
    let repository: SettingsRepository
    private let registry: ProviderRegistry
    private let defaults: AppSettings
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "dictation")
    /// Secret fields loaded from storage whose Keychain import has not
    /// confirmed. Saves keep their plaintext values: while the Keychain is
    /// unreadable they may be the only copy. The importer removes them.
    private var pendingImportSecrets: [String: Set<String>] = [:]

    public struct Change: Sendable {
        public let invalidatedProviders: Set<String>
        public let refreshCredentials: Bool
    }

    public init(persistence: any PersistenceProviding, registry: ProviderRegistry, defaults: AppSettings) {
        self.registry = registry
        self.defaults = defaults
        repository = SettingsRepository(persistence: persistence, registry: registry, defaults: defaults)
        let initial = Self.read(repository, defaults: defaults)
        settings = initial.settings
        loadIssue = initial.issue
        pendingImportSecrets = Self.importPendingSecrets(in: initial.settings, registry: registry)
    }

    public var canRecover: Bool { repository.canRecover }

    public func save(_ updated: AppSettings) {
        save(updated, refreshCredentials: nil)
    }

    /// `refreshCredentials` is forced by callers whose new settings are not
    /// a diff of the previous ones (recovery, reread); nil derives it from
    /// what actually changed.
    func save(_ updated: AppSettings, refreshCredentials: Bool?) {
        let previous = settings
        var scrubbed = updated
        for (name, values) in scrubbed.providerConfigs {
            scrubbed.providerConfigs[name] = sanitized(values, provider: name)
        }
        settings = scrubbed
        do {
            try repository.save(scrubbed)
            saveError = nil
        } catch {
            saveError =
                "Settings could not be saved. \(Self.sentence(error.localizedDescription)) Changes apply until Iris quits."
            logger.error("Settings save failed: \(error.localizedDescription, privacy: .private)")
        }
        let invalidated = changedProviders(from: previous)
        let refresh =
            refreshCredentials ?? (!invalidated.isEmpty || previous.providerName != settings.providerName)
        onChange?(Change(invalidatedProviders: invalidated, refreshCredentials: refresh))
    }

    public func retryLoad() {
        let initial = Self.read(repository, defaults: defaults)
        loadIssue = initial.issue
        guard initial.issue == nil else { return }
        pendingImportSecrets = Self.importPendingSecrets(in: initial.settings, registry: registry)
        if let raw = try? repository.rawPayload(),
            (SettingsRepository.peekSchemaVersion(raw) ?? 1) < initial.settings.schemaVersion
        {
            save(initial.settings, refreshCredentials: true)
        } else {
            let previous = settings
            settings = initial.settings
            // The stamp path saves, which clears a stale save banner. A
            // reread that does not need a write must clear it too: the
            // in-memory edit that failed to persist has been discarded.
            saveError = nil
            onChange?(
                Change(
                    invalidatedProviders: changedProviders(from: previous), refreshCredentials: true))
        }
    }

    /// Secret fields still sitting in preferences, by provider. Reads memory
    /// only: Keychain import and the scrubbing save belong to the app environment.
    func plaintextSecrets() -> [String: [String: String]] {
        Self.plaintextSecrets(in: settings, registry: registry)
    }

    /// Marks these secret fields as confirmed in the Keychain, so later
    /// saves scrub any re-staged plaintext again.
    func confirmImportedSecrets(_ imported: [String: Set<String>]) {
        for (name, fields) in imported {
            pendingImportSecrets[name]?.subtract(fields)
            if pendingImportSecrets[name]?.isEmpty == true { pendingImportSecrets[name] = nil }
        }
    }

    static func plaintextSecrets(
        in settings: AppSettings, registry: ProviderRegistry
    ) -> [String: [String: String]] {
        var found: [String: [String: String]] = [:]
        for (name, values) in settings.providerConfigs {
            let keys =
                registry.descriptor(forName: name)?.persistentSecretKeys
                ?? ProviderConfiguration.wellKnownSecretKeys
            let secrets = values.filter { field, value in
                keys.contains(field) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !secrets.isEmpty { found[name] = secrets }
        }
        return found
    }

    private static func importPendingSecrets(
        in settings: AppSettings, registry: ProviderRegistry
    ) -> [String: Set<String>] {
        plaintextSecrets(in: settings, registry: registry).mapValues { Set($0.keys) }
    }

    /// Settings with the given secret fields removed. Nil when nothing changed,
    /// so a scrub does not rewrite preferences that were already clean.
    func settingsByRemovingSecrets(_ imported: [String: Set<String>]) -> AppSettings? {
        var updated = settings
        var changed = false
        for (name, keys) in imported {
            guard var values = updated.providerConfigs[name] else { continue }
            for key in keys where values.removeValue(forKey: key) != nil {
                changed = true
            }
            updated.providerConfigs[name] = values
        }
        return changed ? updated : nil
    }

    public func recover() {
        do {
            let recovered = try repository.recoverUsingDefaults()
            loadIssue = nil
            pendingImportSecrets = [:]
            save(recovered, refreshCredentials: true)
        } catch {
            saveError =
                "Settings recovery failed. \(Self.sentence(error.localizedDescription)) Saved settings are unchanged."
            logger.error("Settings recovery failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    public func setProvider(_ name: String) {
        guard name != settings.providerName, registry.descriptor(forName: name) != nil else { return }
        logger.info("Switching provider to \(name, privacy: .public).")
        var updated = settings
        updated.providerName = name
        if updated.providerConfigs[name] == nil { updated.providerConfigs[name] = [:] }
        save(updated)
    }

    public func setProviderValue(key: String, value: String, provider: String) {
        let secrets =
            registry.descriptor(forName: provider)?.persistentSecretKeys
            ?? ProviderConfiguration.wellKnownSecretKeys
        guard !secrets.contains(key) else { return }
        var updated = settings
        updated.providerConfigs[provider, default: [:]][key] = value
        save(updated)
    }

    /// Secret fields are dropped before persistence — except ones whose
    /// Keychain import is still pending, which must survive as the only
    /// plaintext copy until the importer confirms and scrubs them.
    private func sanitized(_ values: [String: String], provider: String) -> [String: String] {
        let secrets =
            registry.descriptor(forName: provider)?.persistentSecretKeys
            ?? ProviderConfiguration.wellKnownSecretKeys
        let retained = pendingImportSecrets[provider] ?? []
        return values.filter { field, _ in
            !secrets.contains(field) || retained.contains(field)
        }
    }

    private func changedProviders(from previous: AppSettings) -> Set<String> {
        let names = Set(previous.providerConfigs.keys).union(settings.providerConfigs.keys)
        return Set(
            names.filter {
                Self.speechValues(previous.providerConfigs[$0]) != Self.speechValues(settings.providerConfigs[$0])
            })
    }

    static func speechValues(_ values: [String: String]?) -> [String: String] {
        (values ?? [:]).filter { !RewriteConfiguration.settingKeys.contains($0.key) }
    }

    public static func sentence(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        let terminal: Set<Character> = [".", "!", "?", "…", ")", "]", "}", "\"", "'", "’"]
        return terminal.contains(last) ? trimmed : trimmed + "."
    }

    private static func read(_ repository: SettingsRepository, defaults: AppSettings)
        -> (settings: AppSettings, issue: String?)
    {
        switch repository.load() {
        case .missing(let settings), .loaded(let settings): return (settings, nil)
        case .unsupportedVersion:
            return (
                defaults,
                "These settings were saved by a newer version of Iris. They are unchanged; changes cannot be saved until recovery."
            )
        case .corrupt(_, let message):
            return (
                defaults,
                "Settings could not be decoded. \(sentence(message)) Saved settings are unchanged; retry or recover to save changes."
            )
        case .unavailable(let message):
            return (
                defaults, "Settings could not be read. \(sentence(message)) Retry reading them before saving changes."
            )
        }
    }
}
