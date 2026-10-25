import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// In-memory stand-in for the keychain store, mirroring its contract:
/// missing keys read nil, empty saves are the caller's delete path.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func load(key: String) async throws -> String? {
        locked { store[key] }
    }

    func save(_ value: String, forKey key: String) async throws {
        locked { store[key] = value }
    }

    func delete(key: String) async throws {
        _ = locked { store.removeValue(forKey: key) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Test func hotkeyEditsSurvivePersistenceRoundTrip() throws {
    let persistence = MemoryPersistence()
    var settings = AppSettings.defaults
    settings.hotkey = HotkeyConfiguration(keyCode: 58, modifiers: 0, mode: .toggle)
    try settings.save(to: persistence)
    let loaded = try AppSettings.load(from: persistence)
    #expect(loaded.hotkey.keyCode == 58)
    #expect(loaded.hotkey.mode == .toggle)
    #expect(loaded == settings)
}

@Test func insertionAndPillTogglesSurviveRoundTrip() throws {
    let persistence = MemoryPersistence()
    var settings = AppSettings.defaults
    settings.insertMethod = .paste
    settings.trailingSpace = false
    settings.trailingNewline = true
    settings.reduceMotion = true
    settings.pillTranslucent = false
    settings.waveformColorHex = "34C759"
    try settings.save(to: persistence)
    let loaded = try AppSettings.load(from: persistence)
    #expect(loaded.insertMethod == .paste)
    #expect(loaded.trailingSpace == false)
    #expect(loaded.trailingNewline == true)
    #expect(loaded.reduceMotion == true)
    #expect(loaded.pillTranslucent == false)
    #expect(loaded.waveformColorHex == "34C759")
    #expect(loaded.waveformTint.hex == "34C759")
}

@Test func waveformColorMissingFromLegacyPayloadIsDefault() throws {
    let legacy = """
        {"providerName":"Meta","providerValues":{},"hotkey":{"keyCode":61,"modifiers":0,"mode":"hold"},\
        "insertMethod":"keystroke","trailingSpace":true,"trailingNewline":false,"reduceMotion":false}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(loaded.waveformColorHex == nil)
    #expect(loaded.waveformTint.isDefault)
    #expect(loaded.pillTranslucent == true)
}

@Test func waveformColorInvalidHexFallsBackToDefault() throws {
    let payload = """
        {"providerName":"Meta","providerValues":{},"hotkey":{"keyCode":61,"modifiers":0,"mode":"hold"},\
        "insertMethod":"keystroke","trailingSpace":true,"trailingNewline":false,"reduceMotion":false,\
        "waveformColorHex":"not-a-color"}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(payload.utf8))
    #expect(loaded.waveformColorHex == nil)
    #expect(loaded.waveformTint.isDefault)
}

@Test func legacyCaptionSettingDecodesTolerantly() throws {
    // Payloads written before the caption toggle was removed still carry
    // the key; decoding must ignore it instead of failing.
    let legacy = """
        {"providerName":"Meta","providerValues":{},"hotkey":{"keyCode":61,"modifiers":0,"mode":"hold"},\
        "insertMethod":"keystroke","trailingSpace":true,"trailingNewline":false,\
        "showLiveCaption":false,"reduceMotion":true}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(loaded.providerName == "Meta")
    #expect(loaded.reduceMotion == true)
    #expect(
        loaded
            == AppSettings(
                schemaVersion: 1, hotkey: HotkeyConfiguration(), insertMethod: .keystroke, trailingSpace: true,
                trailingNewline: false, reduceMotion: true))
}

@Test func encodedSettingsNeverContainSecretValues() throws {
    var settings = AppSettings.defaults
    settings.providerValues = ["model": "muse-voice-transcribe-1.0"]
    let data = try JSONEncoder().encode(settings)
    let text = String(data: data, encoding: .utf8) ?? ""
    #expect(!text.contains("sk-live-secret-value"))
    // A caller that stages a secret alongside plain values must scrub it
    // through the descriptor before persisting.
    let registry = testProviderRegistry()
    let descriptor = try #require(registry.descriptor(for: .meta))
    let staged = ["model": "muse-voice-transcribe-1.0", "apiKey": "sk-live-secret-value"]
    let scrubbed = descriptor.sanitizedForPersistence(staged)
    #expect(scrubbed["apiKey"] == nil)
    #expect(scrubbed["model"] == "muse-voice-transcribe-1.0")
}

@Test func descriptorMergeAppliesDefaultsWithoutSecrets() {
    let registry = testProviderRegistry()
    guard let descriptor = registry.descriptor(for: .meta) else {
        Issue.record("Missing meta descriptor")
        return
    }
    let merged = descriptor.merged(with: ["mode": "ENDPOINTING", "apiKey": "staged-in-plain"])
    #expect(merged["mode"] == "ENDPOINTING")
    #expect(merged["audioEncoding"] == "PCM_16KHZ")
    #expect(merged["apiKey"] != "staged-in-plain")
}

@Test func switchingProviderNameSwitchesClientType() {
    let registry = testProviderRegistry()
    let transport = TestTransport()
    let meta = registry.makeClient(
        named: "Meta", config: ProviderConfiguration(provider: .meta, values: [:]),
        transport: transport)
    let mock = registry.makeClient(
        named: "mock", config: ProviderConfiguration(provider: .mock, values: [:]),
        transport: transport)
    #expect(meta is MetaVoiceTranscribeClient)
    #expect(mock is MockTranscriptionClient)
    #expect(!(mock is MetaVoiceTranscribeClient))
    #expect(!(meta is MockTranscriptionClient))
}

@Test func secretStoreRoundTripsAPIKey() async throws {
    let secrets: any SecretStoring = InMemorySecretStore()
    #expect(try await secrets.load(key: "iris.apikey.Meta") == nil)
    try await secrets.save("sk-test", forKey: "iris.apikey.Meta")
    #expect(try await secrets.load(key: "iris.apikey.Meta") == "sk-test")
    try await secrets.delete(key: "iris.apikey.Meta")
    #expect(try await secrets.load(key: "iris.apikey.Meta") == nil)
}

@Test func legacyProviderValuesMigrateIntoTheActiveNamespace() throws {
    let payload = """
        {"providerName":"Meta","providerValues":{"model":"kept-model"}}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(payload.utf8))
    #expect(loaded.providerConfigs == ["Meta": ["model": "kept-model"]])
    #expect(loaded.providerValues == ["model": "kept-model"])
    #expect(loaded.providerConfiguration.string("model") == "kept-model")
}

@Test func providerConfigsRoundTripPerProvider() throws {
    let persistence = MemoryPersistence()
    var settings = AppSettings.defaults
    settings.providerName = "Meta"
    settings.providerValues = ["model": "m1"]
    settings.providerConfigs["Grok"] = ["languageBias": "en"]
    try settings.save(to: persistence)
    let loaded = try AppSettings.load(from: persistence)
    #expect(loaded == settings)
    #expect(loaded.providerValues == ["model": "m1"])
    #expect(loaded.providerConfigs["Grok"] == ["languageBias": "en"])
    let text = String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? ""
    #expect(text.contains("providerConfigs"))
    #expect(!text.contains("providerValues"))
}

@Test func providerConfigurationNeverVendsPlainStoredSecrets() throws {
    // A legacy payload with `apiKey` staged in plain `providerConfigs`
    // must not flow to a client as a plain value.
    let payload = """
        {"providerName":"Meta","providerConfigs":{"Meta":{"model":"m1","apiKey":"sk-plain-legacy","sessionId":"sess-plain"}}}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(payload.utf8))
    #expect(loaded.providerConfiguration.values["apiKey"] == nil)
    #expect(loaded.providerConfiguration.values["sessionId"] == nil)
    #expect(loaded.providerConfiguration.string("model") == "m1")
    let registry = testProviderRegistry()
    let viaRegistry = loaded.providerConfiguration(using: registry)
    #expect(viaRegistry.values["apiKey"] == nil)
    #expect(viaRegistry.string("model") == "m1")
}

@Test func unknownProviderValuesStillDenyListWellKnownSecrets() {
    // Without a registered descriptor there is no `secretKeys` set, but
    // the well-known keys must still be treated as secrets.
    let staged = ["model": "m1", "apiKey": "sk-plain", "sessionId": "sess-plain"]
    let scrubbed = staged.filter { !ProviderConfiguration.wellKnownSecretKeys.contains($0.key) }
    #expect(scrubbed["apiKey"] == nil)
    #expect(scrubbed["sessionId"] == nil)
    #expect(scrubbed["model"] == "m1")
    let settings = AppSettings(
        providerName: "Unknown", providerConfigs: ["Unknown": staged])
    let vended = settings.providerConfiguration(using: ProviderRegistry())
    #expect(vended.values["apiKey"] == nil)
    #expect(vended.values["sessionId"] == nil)
}

@Test func typeDamagedHotkeyIsCorruptionNotASilentReset() throws {
    let persistence = MemoryPersistence()
    let raw = Data(#"{"providerName":"Meta","hotkey":5}"#.utf8)
    try persistence.save(raw, forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .corrupt(let preserved, _) = repository.load() else {
        Issue.record("Type-damaged hotkey must report corrupt, not silently reset the struct")
        return
    }
    #expect(preserved == raw)
}

@Test func insertMethodTypeDamageCorruptsWhileUnknownValuesFallBack() throws {
    let persistence = MemoryPersistence()
    try persistence.save(
        Data(#"{"providerName":"Meta","insertMethod":5}"#.utf8), forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence)
    guard case .corrupt = repository.load() else {
        Issue.record("Type-damaged insertMethod must report corrupt, not silently reset the struct")
        return
    }
    let tolerant = try JSONDecoder().decode(
        AppSettings.self,
        from: Data(#"{"providerName":"Meta","insertMethod":"from-the-future"}"#.utf8))
    #expect(tolerant.insertMethod == .keystroke)
}
