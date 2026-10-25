import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func savingOneRequiredSecretBeforeLoadDoesNotMarkProviderReady() async throws {
    let provider = ControllerProviderFixture()
    var registry = ProviderRegistry()
    registry.register(provider)
    let store = TestSecretStore()
    let connections = ProviderConnections(probe: { _ in })
    let controller = ProviderAccessController(secrets: store, registry: registry, connections: connections)

    #expect(await controller.save("only-key", field: "apiKey", provider: provider.id.name))
    #expect(controller.credentials.state(for: provider.id.name) == .missing)
    #expect(!controller.hasRequiredSecrets(provider.id.name))

    #expect(await controller.save("token", field: "token", provider: provider.id.name))
    #expect(controller.credentials.state(for: provider.id.name) == .saved)
    #expect(controller.hasRequiredSecrets(provider.id.name))
}
