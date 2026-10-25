import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private actor ControllerProbeRecorder {
    private(set) var configurations: [ProviderConfiguration] = []
    func check(_ configuration: ProviderConfiguration) { configurations.append(configuration) }
}

@Test @MainActor func controllerAssemblesOnlyCachedSecretsAndDescriptorNormalizedPlainValues() async throws {
    let store = TestSecretStore()
    let provider = ControllerProviderFixture()
    var registry = ProviderRegistry()
    registry.register(provider)
    try await store.save("  fixture-key \n", forKey: SecretStoreKeys.key(providerName: provider.id.name))
    let recorder = ControllerProbeRecorder()
    let connections = ProviderConnections(probe: { await recorder.check($0) })
    let controller = ProviderAccessController(secrets: store, registry: registry, connections: connections)
    await controller.load(provider.id.name)
    #expect(!controller.hasRequiredSecrets(provider.id.name))
    #expect(await controller.save(" fixture-token ", field: "token", provider: provider.id.name))
    #expect(controller.hasRequiredSecrets(provider.id.name))
    let reads = await store.loadCount
    await controller.load(provider.id.name)
    #expect(await store.loadCount == reads)
    let settings = AppSettings(
        providerName: provider.id.name,
        providerValues: [
            "apiKey": "legacy-key", "token": "legacy-token", "sessionId": "legacy-session", "future": "keep",
        ])
    let config = controller.configuration(for: provider.id.name, settings: settings)
    #expect(config.apiKey == "fixture-key")
    #expect(config.string("token") == "fixture-token")
    #expect(config.string("sessionId") == nil)
    #expect(config.string("languageBias") == "xx")
    #expect(config.string("future") == "keep")
    #expect(config.string("normalizedBy") == provider.id.name)
    await controller.check(provider.id.name, settings: settings)
    #expect(await recorder.configurations == [config])
    #expect(connections.state(for: provider.id.name) == .connected)
}

@Test @MainActor func failedCredentialMutationsKeepTheCachedKeyAndVerifiedConnection() async {
    let store = TestSecretStore()
    let provider = ControllerProviderFixture()
    var registry = ProviderRegistry()
    registry.register(provider)
    let connections = ProviderConnections(probe: { _ in })
    let controller = ProviderAccessController(secrets: store, registry: registry, connections: connections)
    await controller.load(provider.id.name)
    #expect(await controller.save("key", field: "apiKey", provider: provider.id.name))
    #expect(await controller.save("token", field: "token", provider: provider.id.name))
    await controller.check(provider.id.name, settings: .defaults)
    #expect(connections.state(for: provider.id.name) == .connected)
    await store.failMutations(true)
    #expect(!(await controller.save("replacement", field: "apiKey", provider: provider.id.name)))
    #expect(!(await controller.remove(field: "apiKey", provider: provider.id.name)))
    #expect(controller.errors[provider.id.name] != nil)
    #expect(controller.configuration(for: provider.id.name, settings: .defaults).apiKey == "key")
    #expect(connections.state(for: provider.id.name) == .connected)
    await store.failMutations(false)
    #expect(await controller.remove(field: "apiKey", provider: provider.id.name))
    #expect(controller.errors[provider.id.name] == nil)
    #expect(!controller.hasRequiredSecrets(provider.id.name))
    #expect(connections.state(for: provider.id.name) == .notChecked)
}

@Test @MainActor func credentialActivationRequiresAKnownMissingActiveKeyAndAnAPIKeyEdit() async {
    let controller = ProviderAccessController(
        secrets: TestSecretStore(), registry: AppProviderAssembly.defaultRegistry(),
        connections: ProviderConnections(probe: { _ in }))
    #expect(await controller.save("other-key", field: "apiKey", provider: "Grok"))
    #expect(!controller.shouldActivate("Grok", active: "Meta", field: "apiKey"))
    await controller.load("Meta")
    #expect(controller.shouldActivate("Grok", active: "Meta", field: "apiKey"))
    #expect(!controller.shouldActivate("Grok", active: "Meta", field: "token"))
    #expect(!controller.shouldActivate("Grok", active: "Grok", field: "apiKey"))
    #expect(await controller.save("active-key", field: "apiKey", provider: "Meta"))
    #expect(!controller.shouldActivate("Grok", active: "Meta", field: "apiKey"))
}
