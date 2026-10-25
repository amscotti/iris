import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func malformedJSONRecoveryWritesPlaceholderInsteadOfSecretBearingBytes() throws {
    let persistence = MemoryPersistence()
    let apiKey = "sk-malformed-json"
    let sessionId = "session-malformed-json"
    // The missing outer brace makes this unreadable even though the secret
    // field names and values are still visible in the damaged bytes.
    let raw = Data(
        #"{"providerConfigs":{"Meta":{"apiKey":"sk-malformed-json","sessionId":"session-malformed-json","model":"keep-model"}}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())

    guard case .corrupt = repository.load() else {
        Issue.record("Malformed JSON must require recovery")
        return
    }
    #expect(try persistence.load(key: AppSettings.storageKey) == raw)
    #expect(try persistence.load(key: SettingsRepository.backupKey) == nil)

    _ = try repository.recoverUsingDefaults()

    let backup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    expectBytes(backup, toOmit: [apiKey, sessionId])
    try expectRecoveryPlaceholder(backup, originalByteCount: raw.count)
    #expect(try persistence.load(key: AppSettings.storageKey) != raw)
    #expect(try AppSettings.load(from: persistence) == .defaults)
}

@Test func damagedBinaryPropertyListRecoveryRedactsSecretsAndKeepsPlainFields() throws {
    let persistence = MemoryPersistence()
    let apiKey = "sk-binary-plist"
    let sessionId = "session-binary-plist"
    let legacySessionId = "legacy-session-binary-plist"
    let damaged: [String: Any] = [
        "providerName": "Meta",
        "providerConfigs": [
            "Meta": [
                "apiKey": apiKey,
                "sessionId": sessionId,
                "model": "keep-model",
            ]
        ],
        "providerValues": [
            "sessionId": legacySessionId,
            "mode": "keep-mode",
        ],
    ]
    let raw = try PropertyListSerialization.data(
        fromPropertyList: damaged, format: .binary, options: 0)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())

    guard case .corrupt = repository.load() else {
        Issue.record("A property list in the JSON settings slot must require recovery")
        return
    }
    #expect(try persistence.load(key: AppSettings.storageKey) == raw)

    _ = try repository.recoverUsingDefaults()

    let backup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    expectBytes(backup, toOmit: [apiKey, sessionId, legacySessionId])
    var format = PropertyListSerialization.PropertyListFormat.xml
    let object = try #require(
        try PropertyListSerialization.propertyList(from: backup, options: [], format: &format)
            as? [String: Any])
    #expect(format == .binary)
    let configs = try #require(object["providerConfigs"] as? [String: Any])
    let meta = try #require(configs["Meta"] as? [String: Any])
    #expect(meta["apiKey"] == nil)
    #expect(meta["sessionId"] == nil)
    #expect(meta["model"] as? String == "keep-model")
    let legacy = try #require(object["providerValues"] as? [String: Any])
    #expect(legacy["sessionId"] == nil)
    #expect(legacy["mode"] as? String == "keep-mode")
    #expect(try persistence.load(key: AppSettings.storageKey) != raw)
    #expect(try AppSettings.load(from: persistence) == .defaults)
}

@Test func loadRetroactivelySanitizesUnredactableOldBackupWithoutTouchingMainPayload() throws {
    let persistence = MemoryPersistence()
    let apiKey = "sk-old-backup"
    let sessionId = "session-old-backup"
    let oldBackup = Data(
        #"{"providerConfigs":{"Meta":{"apiKey":"sk-old-backup","sessionId":"session-old-backup"}}"#
            .utf8)
    let mainPayload = try JSONEncoder().encode(AppSettings.defaults)
    try persistence.save(oldBackup, forKey: SettingsRepository.backupKey)
    try persistence.save(mainPayload, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())

    guard case .loaded = repository.load() else {
        Issue.record("The valid main payload should load after backup maintenance")
        return
    }

    // Inspect persistence directly: this is the launch/load migration path,
    // not redaction performed lazily by a backup accessor.
    let storedBackup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    expectBytes(storedBackup, toOmit: [apiKey, sessionId])
    try expectRecoveryPlaceholder(storedBackup, originalByteCount: oldBackup.count)
    #expect(try persistence.load(key: AppSettings.storageKey) == mainPayload)
}

@Test func deferredMigrationSaveRetainsLoadedSchemaVersion() throws {
    let persistence = MemoryPersistence()
    let raw = Data(
        #"{"schemaVersion":0,"providerName":"Meta","prompts":[{"id":"ffffffff-ffff-ffff-ffff-ffffffffffff","name":"Keep","template":"t","model":"legacy-model"}]}"#
            .utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)

    guard case .loaded(let settings) = repository.load() else {
        Issue.record("The legacy payload should load with migration deferred")
        return
    }
    #expect(settings.schemaVersion == 0)
    try repository.save(settings)

    let saved = try #require(try persistence.load(key: AppSettings.storageKey))
    #expect(SettingsRepository.peekSchemaVersion(saved) == 0)
}

@Test func malformedEscapedSecretKeyAlsoFailsClosed() throws {
    let raw = Data(#"{"providerConfigs":{"Meta":{"\u0061piKey":"sk-escaped-key"}}"#.utf8)
    let redacted = SettingsRepository.redactingSecrets(from: raw, registry: testProviderRegistry())
    expectBytes(redacted, toOmit: ["sk-escaped-key"])
    try expectRecoveryPlaceholder(redacted, originalByteCount: raw.count)
}

@Test func unknownFutureProviderFieldsCannotSurviveRecoveryBackup() throws {
    let persistence = MemoryPersistence()
    let raw = Data(
        #"{"schemaVersion":999,"providerConfigs":{"Future":{"oauthToken":"future-secret"}}}"#.utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())
    guard case .unsupportedVersion = repository.load() else {
        Issue.record("The future payload should require recovery")
        return
    }
    _ = try repository.recoverUsingDefaults()
    let backup = try #require(try persistence.load(key: SettingsRepository.backupKey))
    expectBytes(backup, toOmit: ["future-secret"])
    try expectRecoveryPlaceholder(backup, originalByteCount: raw.count)
}

@Test func unknownFieldInKnownProviderCannotSurviveRecoveryBackup() throws {
    let raw = Data(#"{"providerConfigs":{"Meta":{"oauthToken":"unknown-secret","model":"keep"}}}"#.utf8)
    let redacted = SettingsRepository.redactingSecrets(from: raw, registry: testProviderRegistry())
    expectBytes(redacted, toOmit: ["unknown-secret"])
    try expectRecoveryPlaceholder(redacted, originalByteCount: raw.count)
}

@Test func malformedValuesUnderKnownKeysCannotHideSecrets() throws {
    let raw = Data(#"{"providerName":{"apiKey":"nested-secret"}}"#.utf8)
    let redacted = SettingsRepository.redactingSecrets(from: raw, registry: testProviderRegistry())
    expectBytes(redacted, toOmit: ["nested-secret"])
    try expectRecoveryPlaceholder(redacted, originalByteCount: raw.count)
}

@Test func placeholderReasonIsCanonicalizedDuringRetroactiveRedaction() throws {
    let raw = Data(
        #"{"irisRecoveryBackupPlaceholder":true,"originalByteCount":42,"reason":"secret-in-reason"}"#
            .utf8)
    let redacted = SettingsRepository.redactingSecrets(from: raw, registry: testProviderRegistry())
    expectBytes(redacted, toOmit: ["secret-in-reason"])
    try expectRecoveryPlaceholder(redacted, originalByteCount: 42)
}

private final class DamagedBackupSlotStore: PersistenceProviding, @unchecked Sendable {
    struct Damage: Error, SettingsRepository.DamagedPayloadPreserving {
        let preservedPayload: Data?
    }

    let mainPayload = Data("unreadable-main".utf8)
    let damagedBackup = Data("unreadable-backup".utf8)
    private var values: [String: Data] = [:]

    func load(key: String) throws -> Data? {
        if key == AppSettings.storageKey { return mainPayload }
        if key == SettingsRepository.backupKey { throw Damage(preservedPayload: damagedBackup) }
        return values[key]
    }

    func save(_ data: Data, forKey key: String) throws { values[key] = data }
    func delete(key: String) throws { values.removeValue(forKey: key) }
}

@Test func damagedBackupSlotDoesNotBlockMainRecovery() throws {
    let store = DamagedBackupSlotStore()
    let repository = SettingsRepository(persistence: store)
    guard case .corrupt = repository.load() else {
        Issue.record("The malformed main payload should require recovery")
        return
    }
    _ = try repository.recoverUsingDefaults()
    let backup = try #require(try repository.loadUnreadableBackup())
    try expectRecoveryPlaceholder(backup, originalByteCount: store.damagedBackup.count)
}

private final class OccupiedDamagedSlotStore: PersistenceProviding, @unchecked Sendable {
    struct Damage: Error, SettingsRepository.DamagedPayloadPreserving {
        let preservedPayload: Data? = nil
    }

    let older = Data(#"{"providerName":"Meta"}"#.utf8)
    let later = Data(#"{"providerName":"Grok"}"#.utf8)
    private var values: [String: Data] = [:]

    func load(key: String) throws -> Data? {
        if key == SettingsRepository.backupKey { return older }
        if key == "\(SettingsRepository.backupKey).2" { throw Damage() }
        if key == "\(SettingsRepository.backupKey).3" { return later }
        return values[key]
    }

    func save(_ data: Data, forKey key: String) throws { values[key] = data }
    func delete(key: String) throws { values.removeValue(forKey: key) }
}

@Test func damagedSlotStillCountsWhenChoosingTheNextBackupSlot() throws {
    let store = OccupiedDamagedSlotStore()
    let repository = SettingsRepository(persistence: store)
    try repository.preserveUnreadable(Data("new-main".utf8))
    #expect(try store.load(key: "\(SettingsRepository.backupKey).3") == store.later)
    #expect(try store.load(key: "\(SettingsRepository.backupKey).4") != nil)
}

private func expectBytes(_ data: Data, toOmit secrets: [String]) {
    for secret in secrets {
        #expect(data.range(of: Data(secret.utf8)) == nil)
    }
}

private func expectRecoveryPlaceholder(_ data: Data, originalByteCount: Int) throws {
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["irisRecoveryBackupPlaceholder"] as? Bool == true)
    #expect(object["originalByteCount"] as? Int == originalByteCount)
    #expect(object["providerConfigs"] == nil)
}
