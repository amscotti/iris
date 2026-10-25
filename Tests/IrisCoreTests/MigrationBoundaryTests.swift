import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func futureTargetDefersInsteadOfStampingAnUnmigratedPayload() {
    var settings = AppSettings(schemaVersion: 2)
    let deferred = SettingsMigrations.apply(
        to: &settings, raw: Data("{}".utf8), registry: testProviderRegistry(), targetVersion: 3)
    #expect(deferred)
    #expect(settings.schemaVersion == 2)
}

@Test func completedV1MigrationReportsOnlyTheVersionItReached() throws {
    var settings = AppSettings(schemaVersion: 1)
    let deferred = SettingsMigrations.apply(
        to: &settings, raw: Data("{}".utf8), registry: testProviderRegistry(), targetVersion: 3)
    #expect(deferred)
    #expect(settings.schemaVersion == 2)
}

@Test func blankLegacyEffortDoesNotFreezeTheProviderDefault() throws {
    let raw = Data(
        #"{"providerName":"Grok","prompts":[{"id":"99999999-9999-9999-9999-999999999999","model":"grok-4.6","effort":" "}]}"#
            .utf8)
    let promptID = try #require(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
    var settings = AppSettings(
        schemaVersion: 1, providerName: "Grok", prompts: [PromptDefinition(id: promptID, template: "x")])
    let deferred = SettingsMigrations.apply(to: &settings, raw: raw, registry: testProviderRegistry())
    #expect(!deferred)
    #expect(settings.providerConfigs["Grok"]?[ProviderConfiguration.Key.rewriteEffort] == nil)
}
