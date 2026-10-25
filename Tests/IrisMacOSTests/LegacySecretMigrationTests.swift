import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func legacyPlaintextImportPreservesExistingSessionSecrets() async throws {
    let fixture = TestEnvironment()
    let sessionKey = try SecretStoreKeys.key(providerName: "Meta", field: "sessionId")
    try await fixture.secrets.save("existing-session", forKey: sessionKey)
    let stored = AppSettings(
        providerName: "Meta",
        providerValues: ["apiKey": "legacy-key", "sessionId": "legacy-session", "languageBias": "English"])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()

    await environment.importPlaintextSecrets()

    #expect(try await fixture.secrets.load(key: sessionKey) == "existing-session")
    #expect(environment.resolvedConfiguration.string("sessionId") == "existing-session")
    let persisted = try persistedLegacySettings(fixture)
    #expect(persisted.providerValues["apiKey"] == nil)
    #expect(persisted.providerValues["sessionId"] == nil)
    #expect(persisted.providerValues["languageBias"] == "English")
    await environment.stop()
}

@Test @MainActor func legacyPlaintextImportResumesAfterKeychainReadRetry() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(providerName: "Meta", providerValues: ["apiKey": "legacy-key"])
    try stored.save(to: fixture.persistence)
    await fixture.secrets.failLoads(true)
    let environment = fixture.make()

    await environment.importPlaintextSecrets()
    #expect(try persistedLegacySettings(fixture).providerValues["apiKey"] == "legacy-key")

    await fixture.secrets.failLoads(false)
    await environment.loadProviderCredentials("Meta", retry: true)

    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta")) == "legacy-key")
    #expect(environment.resolvedConfiguration.apiKey == "legacy-key")
    #expect(environment.credentials.state(for: "Meta") == .saved)
    #expect(try persistedLegacySettings(fixture).providerValues["apiKey"] == nil)
    await environment.stop()
}

@Test @MainActor func legacyPlaintextImportDoesNotRepeatFailedKeychainRetries() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(providerName: "Meta", providerValues: ["apiKey": "legacy-key"])
    try stored.save(to: fixture.persistence)
    await fixture.secrets.failLoads(true)
    let environment = fixture.make()
    await environment.importPlaintextSecrets()
    #expect(await fixture.secrets.loadCount == 1)

    await environment.loadProviderCredentials("Meta", retry: true)

    #expect(await fixture.secrets.loadCount == 2)
    #expect(try persistedLegacySettings(fixture).providerValues["apiKey"] == "legacy-key")
    await environment.stop()
}

@Test @MainActor func legacyPlaintextImportRetriesWritesWithoutDroppingAnotherProvidersSecret() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(
        providerName: "Meta",
        providerConfigs: ["Meta": ["apiKey": "legacy-meta"], "Grok": ["apiKey": "legacy-grok"]])
    try stored.save(to: fixture.persistence)
    await fixture.secrets.failMutations(true)
    let environment = fixture.make()

    await environment.importPlaintextSecrets()
    #expect(try persistedLegacySettings(fixture).providerConfigs == stored.providerConfigs)

    await fixture.secrets.failMutations(false)
    await environment.loadProviderCredentials("Meta", retry: true)

    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta")) == "legacy-meta")
    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Grok")) == "legacy-grok")
    let persisted = try persistedLegacySettings(fixture)
    #expect(persisted.providerConfigs["Meta"]?["apiKey"] == nil)
    #expect(persisted.providerConfigs["Grok"]?["apiKey"] == nil)
    #expect(environment.resolvedConfiguration.apiKey == "legacy-meta")
    await environment.stop()
}

@Test @MainActor func legacyPlaintextImportKeepsAnUnimportedFieldWhenItsUncachedReadFails() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("existing-key", forKey: SecretStoreKeys.key(providerName: "Meta"))
    let stored = AppSettings(
        providerName: "Meta", providerValues: ["apiKey": "legacy-key", "sessionId": "legacy-session"])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()
    await environment.loadProviderCredentials("Meta")
    await fixture.secrets.failLoads(true)

    await environment.importPlaintextSecrets()

    // The cached apiKey imports without a read; the uncached sessionId read
    // fails, so that field's plaintext stays behind as the only copy.
    let persisted = try persistedLegacySettings(fixture)
    #expect(persisted.providerValues["apiKey"] == nil)
    #expect(persisted.providerValues["sessionId"] == "legacy-session")

    await fixture.secrets.failLoads(false)
    await environment.loadProviderCredentials("Meta", retry: true)

    #expect(try persistedLegacySettings(fixture).providerValues["sessionId"] == nil)
    #expect(
        try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta", field: "sessionId"))
            == "legacy-session")
    await environment.stop()
}

@Test @MainActor func settingsSaveKeepsPlaintextWhileItsKeychainImportIsPending() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(providerName: "Meta", providerValues: ["apiKey": "legacy-key"])
    try stored.save(to: fixture.persistence)
    await fixture.secrets.failLoads(true)
    let environment = fixture.make()

    await environment.importPlaintextSecrets()
    environment.setProviderValue(key: "languageBias", value: "English")

    #expect(try persistedLegacySettings(fixture).providerValues["apiKey"] == "legacy-key")

    await fixture.secrets.failLoads(false)
    await environment.saveSecret("replacement-key", field: "apiKey", provider: "Meta")

    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta")) == "replacement-key")
    #expect(environment.resolvedConfiguration.apiKey == "replacement-key")
    #expect(try persistedLegacySettings(fixture).providerValues["apiKey"] == nil)
    await environment.stop()
}

@Test @MainActor func failedImportScrubsFieldsThatWereAlreadyImported() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("existing-key", forKey: SecretStoreKeys.key(providerName: "Meta"))
    let stored = AppSettings(
        providerName: "Meta", providerValues: ["apiKey": "legacy-key", "sessionId": "legacy-session"])
    try stored.save(to: fixture.persistence)
    await fixture.secrets.failMutations(true)
    let environment = fixture.make()

    await environment.importPlaintextSecrets()

    // The cached apiKey imported without a write; the sessionId save failed.
    let persisted = try persistedLegacySettings(fixture)
    #expect(persisted.providerValues["apiKey"] == nil)
    #expect(persisted.providerValues["sessionId"] == "legacy-session")

    await fixture.secrets.failMutations(false)
    await environment.loadProviderCredentials("Meta", retry: true)

    #expect(
        try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta", field: "sessionId"))
            == "legacy-session")
    #expect(try persistedLegacySettings(fixture).providerValues["sessionId"] == nil)
    await environment.stop()
}

@Test @MainActor func degenerateProviderNameIsSkippedWithoutBlockingOtherImports() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(
        providerName: "Meta",
        providerConfigs: [
            "Meta": ["apiKey": "legacy-key", "language": "en"],
            " ": ["apiKey": "degenerate-key"],
        ])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()

    await environment.importPlaintextSecrets()

    // The real provider imports and scrubs even though the degenerate
    // namespace is visited first (sorted order).
    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta")) == "legacy-key")
    let persisted = try persistedLegacySettings(fixture)
    #expect(persisted.providerConfigs["Meta"]?["apiKey"] == nil)
    #expect(persisted.providerConfigs["Meta"]?["language"] == "en")
    // The degenerate namespace cannot address the Keychain; its plaintext
    // stays put instead of aborting the whole chain.
    #expect(persisted.providerConfigs[" "]?["apiKey"] == "degenerate-key")
    await environment.stop()
}

@MainActor
private func persistedLegacySettings(_ fixture: TestEnvironment) throws -> AppSettings {
    try #require(try fixture.persistence.load(key: AppSettings.storageKey, as: AppSettings.self))
}
