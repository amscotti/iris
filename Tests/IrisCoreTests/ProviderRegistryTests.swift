import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

final class MemoryPersistence: PersistenceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]

    func load(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func save(_ data: Data, forKey key: String) throws {
        lock.lock()
        store[key] = data
        lock.unlock()
    }

    func delete(key: String) throws {
        lock.lock()
        store.removeValue(forKey: key)
        lock.unlock()
    }
}

@Test func providerDisplayNameIsCapitalized() {
    #expect(ProviderID.meta.name == "Meta")
    #expect(ProviderID.grok.name == "Grok")
}

@Test func legacySettingsProviderIdentifierMatchesMetaProvider() throws {
    let persistence = MemoryPersistence()
    let stored = Data(#"{"providerValues":{"model":"legacy-model"}}"#.utf8)
    try persistence.save(stored, forKey: AppSettings.storageKey)
    let settings = try AppSettings.load(from: persistence)
    #expect(AppSettings.legacyProviderName == MetaProvider().id.name)
    #expect(settings.providerName == "Meta")
    #expect(settings.providerConfiguration.provider == MetaProvider().id)
    #expect(settings.providerConfiguration.string("model") == "legacy-model")
}

@Test func providersRegisterAndResolveByName() {
    let registry = testProviderRegistry()
    #expect(registry.availableProviders.contains(.meta))
    #expect(registry.availableProviders.contains(.grok))
    #expect(registry.availableProviders.contains(.mock))
    #expect(registry.userFacingProviders.contains(.meta))
    #expect(registry.userFacingProviders.contains(.grok))
    #expect(registry.userFacingProviders.count > 1)
    #expect(!registry.userFacingProviders.contains(.mock))
    let transport = TestTransport()
    let config = ProviderConfiguration(provider: .meta, values: [:])
    #expect(
        registry.makeClient(named: "Grok", config: ProviderConfiguration(provider: .grok), transport: transport)
            is GrokVoiceTranscribeClient)
    #expect(registry.makeClient(named: "Grok", config: config, transport: transport) == nil)
    #expect(registry.makeClient(named: "Meta", config: config, transport: transport) is MetaVoiceTranscribeClient)
    let mockConfig = ProviderConfiguration(provider: .mock, values: [:])
    #expect(registry.makeClient(named: "mock", config: mockConfig, transport: transport) is MockTranscriptionClient)
    #expect(registry.makeClient(named: "nope", config: config, transport: transport) == nil)
}

@Test func metaDescriptorCoversHandshakeFields() {
    let registry = testProviderRegistry()
    guard let descriptor = registry.descriptor(for: .meta) else {
        Issue.record("Missing meta descriptor")
        return
    }
    #expect(descriptor.field(for: "apiKey")?.type == .secret)
    #expect(
        descriptor.field(for: "audioEncoding")?.type
            == .enum(cases: ["PCM_16KHZ", "PCM_24KHZ"]))
    #expect(descriptor.field(for: "mode")?.defaultValue == "PUSH_TO_TALK")
    #expect(
        descriptor.field(for: "model")?.type
            == .enumAllowingCustom(cases: ["muse-voice-transcribe-1.0"]))
    #expect(descriptor.field(for: "languageBias")?.defaultValue == MetaLanguageBias.auto)
    #expect(descriptor.field(for: "languageBias")?.type.presetCases?.contains("English") == true)
    #expect(descriptor.field(for: "keywords")?.label == "Custom words")
    let values = descriptor.defaultValues()
    #expect(values["audioEncoding"] == "PCM_16KHZ")
    #expect(values["languageBias"] == MetaLanguageBias.auto)
}

@Test func registryAcceptsNewProviders() {
    var registry = ProviderRegistry()
    let id = ProviderID("demo")
    registry.register(
        id,
        descriptor: ConfigDescriptor(fields: [
            ConfigField(key: "token", label: "Token", type: .secret, defaultValue: "")
        ]),
        factory: { _, _ in MockTranscriptionClient() })
    #expect(registry.availableProviders.contains(id))
    let client = registry.makeClient(
        named: "demo", config: ProviderConfiguration(provider: id), transport: TestTransport())
    #expect(client is MockTranscriptionClient)
}

@Test func customModelFieldOffersPresetsPlusFreeEntry() {
    let registry = testProviderRegistry()
    guard let descriptor = registry.descriptor(for: .meta) else {
        Issue.record("Missing meta descriptor")
        return
    }
    guard let model = descriptor.field(for: "model") else {
        Issue.record("Missing model field")
        return
    }
    #expect(model.type.allowsCustom)
    #expect(model.type.presetCases == ["muse-voice-transcribe-1.0"])
    #expect(model.advanced)
    for key in ["mode", "audioEncoding", "languageBias", "keywords", "apiKey"] {
        #expect(descriptor.field(for: key)?.type.allowsCustom == false)
    }
}

@Test func customModelSelectionRoundTripsStoredValues() {
    let tag = "__iris_custom__"
    let type = ConfigFieldType.enumAllowingCustom(cases: ["muse-voice-transcribe-1.0"])
    // A stored preset selects that preset.
    #expect(type.pickerSelection(for: "muse-voice-transcribe-1.0", customTag: tag) == "muse-voice-transcribe-1.0")
    // A stored custom name selects the custom row, keeping the real string.
    #expect(type.pickerSelection(for: "future-model-9", customTag: tag) == tag)
    // An empty effective value (unresolved default handled by the caller)
    // falls back to the custom row rather than a phantom preset.
    #expect(type.pickerSelection(for: "", customTag: tag) == tag)
    // Plain enums pass values through untouched: no custom affordance.
    let plain = ConfigFieldType.enum(cases: ["PCM_16KHZ", "PCM_24KHZ"])
    #expect(plain.pickerSelection(for: "PCM_24KHZ", customTag: tag) == "PCM_24KHZ")
    #expect(plain.pickerSelection(for: "whatever", customTag: tag) == "whatever")
    #expect(plain.presetCases == ["PCM_16KHZ", "PCM_24KHZ"])
    #expect(ConfigFieldType.string.presetCases == nil)
}

@Test func grokDescriptorCoversStreamingFields() {
    let registry = testProviderRegistry()
    guard let descriptor = registry.descriptor(for: .grok) else {
        Issue.record("Missing grok descriptor")
        return
    }
    #expect(descriptor.field(for: "apiKey")?.type == .secret)
    #expect(
        descriptor.field(for: "model")?.type
            == .enumAllowingCustom(cases: ["grok-voice-transcribe-2.0", "grok-voice-transcribe-1.0"]))
    #expect(descriptor.field(for: "model")?.defaultValue == "grok-voice-transcribe-2.0")
    #expect(descriptor.field(for: "model")?.advanced == true)
    #expect(descriptor.field(for: "audioEncoding") == nil)
    #expect(descriptor.field(for: "languageBias")?.defaultValue == GrokLanguage.auto)
    #expect(descriptor.field(for: "languageBias")?.type.presetCases?.contains("en") == true)
    #expect(descriptor.field(for: "keywords")?.label == "Custom words")
    let essentialKeys = Set(descriptor.essentialFields.map(\.key))
    let advancedKeys = Set(descriptor.advancedFields.map(\.key))
    #expect(essentialKeys == ["apiKey", "languageBias", "keywords"])
    #expect(advancedKeys == ["model", "rewriteModel", "rewriteEffort"])
    #expect(descriptor.field(for: "rewriteModel")?.defaultValue == "grok-4.6")
    #expect(descriptor.field(for: "rewriteEffort")?.defaultValue == "low")
    #expect(GrokProvider().completionPolicy(for: ProviderConfiguration(provider: .grok)) == .finalEvent)
}

@Test func advancedFieldsSplitFromEssentials() {
    let registry = testProviderRegistry()
    guard let descriptor = registry.descriptor(for: .meta) else {
        Issue.record("Missing meta descriptor")
        return
    }
    let essentialKeys = Set(descriptor.essentialFields.map { $0.key })
    let advancedKeys = Set(descriptor.advancedFields.map { $0.key })
    #expect(essentialKeys == ["apiKey", "languageBias", "keywords"])
    #expect(advancedKeys == ["model", "mode", "rewriteModel", "rewriteEffort"])
    #expect(descriptor.field(for: "rewriteModel")?.defaultValue == "muse-spark-1.3")
    #expect(descriptor.field(for: "rewriteEffort")?.defaultValue == "minimal")
    #expect(essentialKeys.isDisjoint(with: advancedKeys))
    #expect(
        descriptor.essentialFields.count + descriptor.advancedFields.count
            == descriptor.fields.filter(\.isVisible).count)
    #expect(descriptor.field(for: "audioEncoding")?.isVisible == false)
}

@Test func settingsPersistAndMapToProviderConfig() throws {
    let persistence = MemoryPersistence()
    var settings = AppSettings.defaults
    settings.providerName = "Meta"
    settings.providerValues = ["audioEncoding": "PCM_24KHZ"]
    try settings.save(to: persistence)
    let loaded = try AppSettings.load(from: persistence)
    #expect(loaded == settings)
    #expect(loaded.providerConfiguration.provider == .meta)
    #expect(loaded.providerConfiguration.string("audioEncoding") == "PCM_24KHZ")
    #expect(AppSettings.defaults.trailingSpace)
}
