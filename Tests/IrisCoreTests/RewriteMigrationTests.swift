import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func migrate(_ json: String) throws -> AppSettings {
    let store = MemoryPersistence()
    try store.save(Data(json.utf8), forKey: AppSettings.storageKey)
    return try AppSettings.load(from: store, registry: testProviderRegistry())
}

private func rewrite(_ settings: AppSettings, provider: ProviderID) -> RewriteConfiguration? {
    RewriteConfiguration(
        config: ProviderConfiguration(provider: provider, values: settings.providerConfigs[provider.name] ?? [:]),
        registry: testProviderRegistry())
}

@Test func activeLegacyPromptSeedsProviderSettingsAndKeepsText() throws {
    let settings = try migrate(
        """
        {
          "providerName": "Meta",
          "providerConfigs": {"Meta": {"languageBias": "French"}, "Grok": {"languageBias": "en"}},
          "selectedPromptID": "22222222-2222-2222-2222-222222222222",
          "prompts": [
            {"id":"11111111-1111-1111-1111-111111111111","name":"First","template":"First text","model":"muse-spark-1.3","effort":"minimal","order":0},
            {"id":"22222222-2222-2222-2222-222222222222","name":"Selected","template":"Keep this {{transcript}}","model":"custom-meta","effort":"high","order":1}
          ]
        }
        """)
    #expect(rewrite(settings, provider: .meta)?.model == "custom-meta")
    #expect(rewrite(settings, provider: .meta)?.effort == .high)
    #expect(settings.providerConfigs["Meta"]?["languageBias"] == "French")
    #expect(settings.providerConfigs["Grok"] == ["languageBias": "en"])
    #expect(settings.selectedPrompt?.template == "Keep this {{transcript}}")
    #expect(settings.prompts.map(\.name) == ["First", "Selected"])
    #expect(settings.prompts.map(\.order) == [0, 1])
}

@Test func legacyChoicesFollowPromptIDsWhenDecodedOrderChanges() throws {
    let selectedID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    let otherID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    var settings = AppSettings(
        schemaVersion: 1, providerName: "Meta",
        prompts: [
            PromptDefinition(id: otherID, name: "Other", template: "Other", order: 0),
            PromptDefinition(id: selectedID, name: "Selected", template: "Selected", order: 0),
        ], selectedPromptID: selectedID)
    let raw = Data(
        """
        {"prompts":[
          {"id":"11111111-1111-1111-1111-111111111111","model":"muse-selected","effort":"high"},
          {"id":"22222222-2222-2222-2222-222222222222","model":"muse-other","effort":"minimal"}
        ]}
        """.utf8)

    SettingsMigrations.apply(to: &settings, raw: raw, registry: testProviderRegistry())

    #expect(rewrite(settings, provider: .meta)?.model == "muse-selected")
    #expect(rewrite(settings, provider: .meta)?.effort == .high)
}

@Test func legacyModelFamiliesMigrateToTheirOwnProviders() throws {
    let settings = try migrate(
        """
        {
          "providerName":"Meta",
          "selectedPromptID":"22222222-2222-2222-2222-222222222222",
          "prompts":[
            {"id":"11111111-1111-1111-1111-111111111111","template":"Meta-era text","model":"muse-spark-1.3","effort":"minimal"},
            {"id":"22222222-2222-2222-2222-222222222222","template":"Shared text","model":"grok-4.6","effort":"max"}
          ]
        }
        """)
    #expect(rewrite(settings, provider: .meta)?.model == "muse-spark-1.3")
    #expect(rewrite(settings, provider: .meta)?.effort == .minimal)
    #expect(rewrite(settings, provider: .grok)?.model == "grok-4.6")
    #expect(rewrite(settings, provider: .grok)?.effort == .xhigh)
    #expect(settings.selectedPrompt?.template == "Shared text")
}

@Test func existingProviderRewriteSettingsWinOverLegacyChoices() throws {
    let settings = try migrate(
        """
        {
          "providerName":"Grok",
          "providerConfigs":{"Grok":{"rewriteModel":"grok-provider-choice","rewriteEffort":"low"}},
          "prompts":[{"id":"33333333-3333-3333-3333-333333333333","name":"Old prompt","model":"grok-4.6","effort":"xhigh","template":"Keep this text"}]
        }
        """)
    #expect(rewrite(settings, provider: .grok)?.model == "grok-provider-choice")
    #expect(rewrite(settings, provider: .grok)?.effort == .low)
    #expect(settings.prompts.first?.template == "Keep this text")
    #expect(settings.selectedPromptID == nil)
}

@Test func missingLegacySelectionUsesFirstCompatiblePromptInDisplayOrder() throws {
    let settings = try migrate(
        """
        {
          "providerName":"Meta",
          "prompts":[
            {"id":"44444444-4444-4444-4444-444444444444","name":"Later","model":"muse-later","effort":"high","order":5},
            {"id":"55555555-5555-5555-5555-555555555555","name":"Earlier","model":"muse-earlier","effort":"minimal","order":0}
          ]
        }
        """)
    #expect(rewrite(settings, provider: .meta)?.model == "muse-earlier")
    #expect(rewrite(settings, provider: .meta)?.effort == .minimal)
    #expect(settings.selectedPromptID == nil)
}

@Test func blankLegacyModelUsesActiveProviderDefaults() throws {
    let settings = try migrate(
        #"{"providerName":"Grok","prompts":[{"id":"99999999-9999-9999-9999-999999999999","model":" ","effort":"minimal"}]}"#
    )
    #expect(rewrite(settings, provider: .grok)?.model == "grok-4.6")
    #expect(rewrite(settings, provider: .grok)?.effort == .low)
    #expect(settings.providerConfigs["Grok"]?[ProviderConfiguration.Key.rewriteModel] == nil)
    #expect(settings.providerConfigs["Grok"]?[ProviderConfiguration.Key.rewriteEffort] == "low")
    #expect(settings.providerConfigs["Meta"] == nil)
}

@Test func rewriteMigrationIsIdempotentAndNewPromptsPersistAsTextOnly() throws {
    var settings = try migrate(
        #"{"providerName":"Meta","prompts":[{"id":"66666666-6666-6666-6666-666666666666","name":"Cleanup","template":"Clean {{transcript}}","model":"custom-meta","effort":"low"}]}"#
    )
    settings.providerName = "Grok"
    let encoded = try JSONEncoder().encode(settings)
    let reloaded = try JSONDecoder().decode(AppSettings.self, from: encoded)
    #expect(reloaded == settings)
    #expect(rewrite(reloaded, provider: .meta)?.model == "custom-meta")
    #expect(rewrite(reloaded, provider: .grok)?.model == "grok-4.6")
    let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let prompts = try #require(object["prompts"] as? [[String: Any]])
    #expect(Set(prompts[0].keys) == ["id", "name", "template", "order"])
}

@Test func unattributableLegacyChoicesDeferEvenWithDescriptorsRegistered() throws {
    // Descriptors exist, but the active provider is not a rewriter and no
    // descriptor recognizes the model: stamping would discard the choice
    // exactly like the empty-registry case, so the payload stays unstamped.
    let persistence = MemoryPersistence()
    try persistence.save(
        Data(
            #"{"schemaVersion":1,"providerName":"mock","prompts":[{"id":"77777777-7777-7777-7777-777777777777","name":"Keep","template":"Keep this","model":"nobody-knows-it","effort":"high"}]}"#
                .utf8), forKey: AppSettings.storageKey)
    let repository = SettingsRepository(persistence: persistence, registry: testProviderRegistry())
    guard case .loaded(let settings) = repository.load() else {
        Issue.record("v1 payload should load")
        return
    }
    #expect(settings.schemaVersion == 1)
    try repository.save(settings)

    let saved = try #require(try persistence.load(key: AppSettings.storageKey))
    #expect(SettingsRepository.peekSchemaVersion(saved) == 1)
    let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    let prompts = try #require(object["prompts"] as? [[String: Any]])
    #expect(prompts.first?["model"] as? String == "nobody-knows-it")
    #expect(prompts.first?["effort"] as? String == "high")

    // The same shape with a model some descriptor recognizes still
    // migrates and stamps.
    try persistence.save(
        Data(
            #"{"schemaVersion":1,"providerName":"mock","prompts":[{"id":"88888888-8888-8888-8888-888888888888","name":"Keep","template":"Keep this","model":"grok-4.6","effort":"max"}]}"#
                .utf8), forKey: AppSettings.storageKey)
    let migrating = SettingsRepository(persistence: persistence, registry: testProviderRegistry())
    guard case .loaded(let migrated) = migrating.load() else {
        Issue.record("Recognized payload should load")
        return
    }
    #expect(migrated.schemaVersion == SettingsRepository.currentVersion)
    #expect(migrated.providerConfigs["Grok"]?[ProviderConfiguration.Key.rewriteModel] == "grok-4.6")
}
