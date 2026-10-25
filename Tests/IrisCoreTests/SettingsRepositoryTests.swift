import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func missingSettingsLoadDefaults() {
    let repository = SettingsRepository(persistence: MemoryPersistence())
    guard case .missing(let settings) = repository.load() else {
        Issue.record("Missing payload must load defaults")
        return
    }
    #expect(settings == .defaults)
}

@Test func corruptPayloadIsPreservedNotReplaced() throws {
    let persistence = MemoryPersistence()
    let raw = Data(#"{"providerName":999}"#.utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .corrupt(let preserved, _) = repository.load() else {
        Issue.record("Unreadable payload must report corrupt")
        return
    }
    #expect(preserved == raw)
    try repository.preserveUnreadable(preserved)
    let backup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    #expect(try placeholderByteCount(backup) == raw.count)
    // The corrupt main payload is untouched until an explicit save.
    #expect(try persistence.load(key: AppSettings.storageKey) == raw)
}

@Test func unsupportedVersionIsPreserved() throws {
    let persistence = MemoryPersistence()
    let raw = Data(#"{"schemaVersion":999,"providerName":"Meta"}"#.utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .unsupportedVersion(let found, let preserved) = repository.load() else {
        Issue.record("Future schema must report unsupportedVersion")
        return
    }
    #expect(found == 999)
    #expect(preserved == raw)
}

@Test func unknownInsertMethodFallsBackWithoutDiscardingPrompts() throws {
    let persistence = MemoryPersistence()
    let raw = Data(
        #"{"providerName":"Meta","insertMethod":"future-method","prompts":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"Keep me","template":"Keep this"}]}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .loaded(let settings) = repository.load() else {
        Issue.record("Unknown enum values must fall back per-field, not reject the payload")
        return
    }
    #expect(settings.insertMethod == .keystroke)
    #expect(settings.prompts.count == 1)
    #expect(settings.prompts.first?.template == "Keep this")
}

@Test func saveWritesCurrentVersionAndRoundTrips() throws {
    let persistence = MemoryPersistence()
    let repository = SettingsRepository(persistence: persistence)
    var settings = AppSettings.defaults
    settings.trailingSpace = false
    try repository.save(settings)
    guard case .loaded(let reloaded) = repository.load() else {
        Issue.record("Saved settings must reload")
        return
    }
    #expect(reloaded.trailingSpace == false)
    #expect(reloaded.schemaVersion == SettingsRepository.currentVersion)
}

@Test func unreadableSettingsBlockOrdinarySavesEvenAfterBackingUp() throws {
    let store = FaultingSettingsStore()
    let raw = Data(#"{"schemaVersion":999,"prompts":[{"template":"keep"}]}"#.utf8)
    try store.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: store)
    _ = repository.load()
    try repository.preserveUnreadable(raw)
    #expect(throws: SettingsRepository.RepositoryError.self) { try repository.save(.defaults) }
    #expect(try store.load(key: AppSettings.storageKey) == raw)
}

@Test func failedBackupNeverOverwritesOriginalSettings() throws {
    let store = FaultingSettingsStore()
    let raw = Data("unreadable".utf8)
    try store.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: store)
    _ = repository.load()
    store.failBackup = true
    #expect(throws: FaultingSettingsStore.Failure.self) { try repository.recoverUsingDefaults() }
    #expect(throws: SettingsRepository.RepositoryError.self) { try repository.save(.defaults) }
    #expect(try store.load(key: AppSettings.storageKey) == raw)
    #expect(try repository.loadUnreadableBackup() == nil)
    store.failBackup = false
    let recovered = try repository.recoverUsingDefaults()
    #expect(recovered == .defaults)
    let backup = try #require(try repository.loadUnreadableBackup())
    #expect(try placeholderByteCount(backup) == raw.count)
    try repository.save(recovered)
}

@Test func failedReadNeedsSuccessfulRetryBeforeAnyWrite() throws {
    let store = FaultingSettingsStore()
    let saved = AppSettings(prompts: [PromptDefinition(template: "Keep me")])
    try saved.save(to: store)
    let original = try store.load(key: AppSettings.storageKey)
    store.failReads = true
    let repository = SettingsRepository(persistence: store)
    guard case .unavailable = repository.load() else {
        Issue.record("Expected read failure")
        return
    }
    #expect(!repository.canRecover)
    store.failReads = false
    #expect(throws: SettingsRepository.RepositoryError.self) { try repository.save(.defaults) }
    #expect(throws: SettingsRepository.RepositoryError.self) { try repository.recoverUsingDefaults() }
    #expect(try store.load(key: AppSettings.storageKey) == original)
    guard case .loaded(let restored) = repository.load() else {
        Issue.record("Retry must reload")
        return
    }
    #expect(restored == saved)
    try repository.save(restored)
}

@Test func persistenceSaveFailuresPropagate() throws {
    let store = FaultingSettingsStore()
    let repository = SettingsRepository(persistence: store)
    _ = repository.load()
    store.failWrites = true
    #expect(throws: FaultingSettingsStore.Failure.self) { try repository.save(.defaults) }
}

@Test func recoveryPreservesEmptyPayloadAndOlderBackups() throws {
    let store = FaultingSettingsStore()
    let older = Data(#"{"providerName":"Meta"}"#.utf8)
    try store.save(older, forKey: SettingsRepository.backupKey)
    try store.save(Data(), forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: store)
    _ = repository.load()
    _ = try repository.recoverUsingDefaults()
    #expect(try repository.loadUnreadableBackup() == older)
}

@Test func sequentialRecoveriesStayDiscoverableInOrder() throws {
    let persistence = MemoryPersistence()
    let first = Data("first unreadable".utf8)
    let second = Data("second unreadable".utf8)
    try persistence.save(first, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    _ = repository.load()
    _ = try repository.recoverUsingDefaults()
    // A second, distinct unreadable payload must not orphan the newest
    // bytes: overflow lands in a deterministic slot, not a UUID key.
    try persistence.save(second, forKey: AppSettings.storageKey)
    _ = repository.load()
    _ = try repository.recoverUsingDefaults()
    let backups = try repository.loadAllUnreadableBackups()
    #expect(backups.count == 2)
    #expect(try placeholderByteCount(backups[0]) == first.count)
    #expect(try placeholderByteCount(backups[1]) == second.count)
}

@Test func promptWithoutIDIsTreatedAsCorruptAndPreserved() throws {
    let persistence = MemoryPersistence()
    let raw = Data(#"{"providerName":"Meta","prompts":[{"name":"No id","template":"t"}]}"#.utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .corrupt(let preserved, _) = repository.load() else {
        Issue.record("A prompt without an id must report corrupt, not regenerate one")
        return
    }
    #expect(preserved == raw)
}

@Test func existingRecoveryBackupsAreRetroactivelyRedacted() throws {
    let persistence = MemoryPersistence()
    let first = Data(
        #"{"providerConfigs":{"Meta":{"apiKey":"[REDACTED]","model":"first-model"}}}"#.utf8)
    let second = Data(
        #"{"providerConfigs":{"Meta":{"sessionId":"second-secret","model":"second-model"}}}"#.utf8)
    try persistence.save(first, forKey: SettingsRepository.backupKey)
    try persistence.save(second, forKey: "\(SettingsRepository.backupKey).2")
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())

    let backups = try repository.loadAllUnreadableBackups()
    #expect(backups.count == 2)
    let combined = backups.compactMap { String(data: $0, encoding: .utf8) }.joined()
    #expect(!combined.contains("[REDACTED]"))
    #expect(!combined.contains("second-secret"))
    #expect(combined.contains("first-model"))
    #expect(combined.contains("second-model"))
    // The stored copies were rewritten, not merely redacted in memory.
    #expect(try persistence.load(key: SettingsRepository.backupKey) == backups[0])
    #expect(try persistence.load(key: "\(SettingsRepository.backupKey).2") == backups[1])
}

@Test func recoveryBackupsRedactPlaintextSecretsButKeepPlainFields() throws {
    let persistence = MemoryPersistence()
    // Undecodable (prompt without id) while carrying plaintext secrets, so
    // the payload can only ever reach the recovery backup — that copy must
    // not keep the secrets.
    let raw = Data(
        #"{"schemaVersion":1,"providerName":"Meta","providerConfigs":{"Meta":{"apiKey":"sk-plain-key","sessionId":"sess-plain","model":"keep-model"},"Grok":{"sessionId":"grok-sess","languageBias":"en"},"Corrupt":"not-a-dict"},"prompts":[{"name":"No id","template":"t"}]}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())
    guard case .corrupt = repository.load() else {
        Issue.record("Undecodable payload must report corrupt")
        return
    }
    _ = try repository.recoverUsingDefaults()

    let backup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    let text = try #require(String(data: backup, encoding: .utf8))
    #expect(!text.contains("sk-plain-key"))
    #expect(!text.contains("sess-plain"))
    #expect(!text.contains("grok-sess"))
    // Non-secret settings survive so the backup stays useful.
    let object = try #require(try JSONSerialization.jsonObject(with: backup) as? [String: Any])
    let configs = try #require(object["providerConfigs"] as? [String: Any])
    let meta = try #require(configs["Meta"] as? [String: Any])
    let grok = try #require(configs["Grok"] as? [String: Any])
    #expect(meta["apiKey"] == nil)
    #expect(meta["sessionId"] == nil)
    #expect(meta["model"] as? String == "keep-model")
    #expect(grok["sessionId"] == nil)
    #expect(grok["languageBias"] as? String == "en")
    #expect(try AppSettings.load(from: persistence) == .defaults)
}

private final class DamagedValueStore: PersistenceProviding, @unchecked Sendable {
    struct DamagedRead: Error, SettingsRepository.DamagedPayloadPreserving {
        let preservedPayload: Data?
    }

    static let serializedDamage = Data("damaged-plist-bytes".utf8)
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(key: String) throws -> Data? {
        try lock.withLock {
            if key == AppSettings.storageKey { throw DamagedRead(preservedPayload: Self.serializedDamage) }
            return values[key]
        }
    }
    func save(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func delete(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

@Test func damagedButPreservableReadBacksUpSerializedBytesAndRecovers() throws {
    let store = DamagedValueStore()
    let repository = SettingsRepository(persistence: store)
    guard case .unavailable = repository.load() else {
        Issue.record("A damaged value must read as unreadable, not missing")
        return
    }
    #expect(repository.canRecover)
    let recovered = try repository.recoverUsingDefaults()
    #expect(recovered == .defaults)
    let backup = try #require(try repository.loadUnreadableBackup())
    #expect(try placeholderByteCount(backup) == DamagedValueStore.serializedDamage.count)
    // Writable again after the backed-up recovery.
    try repository.save(recovered)
}

@Test func legacyChoicesWithoutDescriptorsStayUnstamped() throws {
    let persistence = MemoryPersistence()
    let raw = Data(
        #"{"schemaVersion":1,"providerName":"Meta","prompts":[{"id":"cccccccc-cccc-cccc-cccc-cccccccccccc","name":"Keep","template":"t","effort":"high"}]}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .loaded(let settings) = repository.load() else {
        Issue.record("v1 payload should load")
        return
    }
    // No rewriters registered: migration cannot map the legacy choices, so
    // the version must stay 1 for a later load with the real registry, even
    // when a newly constructed AppSettings (defaulting to currentVersion) is saved.
    #expect(settings.schemaVersion == 1)
    #expect(settings.prompts.count == 1)
    #expect(settings.prompts.first?.template == "t")
    try repository.save(AppSettings(providerName: "Meta", prompts: settings.prompts))
    let saved = try #require(try persistence.load(key: AppSettings.storageKey))
    #expect(SettingsRepository.peekSchemaVersion(saved) == 1)
}

@Test func deferredMigrationSaveStaysUnstampedAndKeepsLegacyPromptChoices() throws {
    let persistence = MemoryPersistence()
    let raw = Data(
        #"{"schemaVersion":1,"providerName":"Meta","prompts":[{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd","name":"Keep","template":"Keep this","model":"grok-4.6","effort":"max"}]}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .loaded(var settings) = repository.load() else {
        Issue.record("v1 payload should load")
        return
    }
    settings.providerName = "Grok"
    settings.prompts[0].name = "Renamed"
    settings.prompts[0].template = "Edited text"
    try repository.save(settings)

    let saved = try #require(try persistence.load(key: AppSettings.storageKey))
    #expect(SettingsRepository.peekSchemaVersion(saved) == 1)
    let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(object["providerName"] as? String == "Grok")
    let prompts = try #require(object["prompts"] as? [[String: Any]])
    // The edit wins; the legacy-only choices survive for the later migration.
    #expect(prompts.first?["name"] as? String == "Renamed")
    #expect(prompts.first?["template"] as? String == "Edited text")
    #expect(prompts.first?["model"] as? String == "grok-4.6")
    #expect(prompts.first?["effort"] as? String == "max")

    let migrating = SettingsRepository(persistence: persistence, registry: testProviderRegistry())
    guard case .loaded(let migrated) = migrating.load() else {
        Issue.record("A descriptor-bearing load must migrate the preserved choices")
        return
    }
    #expect(migrated.schemaVersion == SettingsRepository.currentVersion)
    #expect(migrated.providerConfigs["Grok"]?[ProviderConfiguration.Key.rewriteModel] == "grok-4.6")
}

@Test func deferredSaveDropsLegacyEnabledSoANoneSelectionStaysNone() throws {
    let persistence = MemoryPersistence()
    let raw = Data(
        #"{"schemaVersion":1,"providerName":"Meta","prompts":[{"id":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","name":"Keep","template":"t","enabled":true,"model":"m","effort":"high"}]}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .loaded(var settings) = repository.load() else {
        Issue.record("v1 payload should load")
        return
    }
    // Load-time fallback adopts the legacy enabled prompt; the person then
    // deliberately selects None.
    #expect(settings.selectedPromptID != nil)
    settings.selectedPromptID = nil
    try repository.save(settings)

    guard case .loaded(let reloaded) = repository.load() else {
        Issue.record("Saved settings must reload")
        return
    }
    #expect(reloaded.selectedPromptID == nil)
    // The preserved legacy choices survive for a later descriptor-bearing
    // load; the legacy enabled toggle does not.
    let saved = try #require(try persistence.load(key: AppSettings.storageKey))
    let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    let prompts = try #require(object["prompts"] as? [[String: Any]])
    #expect(prompts.first?["enabled"] == nil)
    #expect(prompts.first?["model"] as? String == "m")
    #expect(prompts.first?["effort"] as? String == "high")
}

private func placeholderByteCount(_ data: Data) throws -> Int? {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["irisRecoveryBackupPlaceholder"] as? Bool == true)
    return object?["originalByteCount"] as? Int
}
