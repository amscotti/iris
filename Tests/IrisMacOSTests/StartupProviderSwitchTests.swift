import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private actor DelayedStartupSecrets: SecretStoring {
    private var pending: [String: CheckedContinuation<String?, Never>] = [:]
    nonisolated let requests: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: String.self)
        requests = stream.stream
        continuation = stream.continuation
    }

    func load(key: String) async throws -> String? {
        await withCheckedContinuation { continuation in
            pending[key] = continuation
            self.continuation.yield(key)
        }
    }

    func completeLoad(key: String, value: String? = nil) {
        pending.removeValue(forKey: key)?.resume(returning: value)
    }

    func save(_ value: String, forKey key: String) async throws {}
    func delete(key: String) async throws {}
}

@Test @MainActor func providerSwitchDuringLaunchCannotStartWithUnresolvedCredentials() async throws {
    let secrets = DelayedStartupSecrets()
    let fixture = TestEnvironment()
    let environment = fixture.make(
        secretStore: secrets,
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true))
    var requests = secrets.requests.makeAsyncIterator()
    let starting = Task { await environment.start() }

    #expect(await requests.next() == "iris.apikey.Meta")
    environment.setProvider("Grok")
    await secrets.completeLoad(key: "iris.apikey.Meta")
    #expect(await requests.next() == "iris.secret.Meta.sessionId")
    await secrets.completeLoad(key: "iris.secret.Meta.sessionId")
    #expect(await requests.next() == "iris.apikey.Grok")
    await secrets.completeLoad(key: "iris.apikey.Grok")
    #expect(await requests.next() == "iris.secret.Grok.sessionId")
    await secrets.completeLoad(key: "iris.secret.Grok.sessionId")
    await starting.value

    #expect(environment.settings.providerName == "Grok")
    #expect(environment.resolvedConfiguration.provider.name == "Grok")
    #expect(!environment.runtime.isMonitoring)
    #expect(environment.startupLimited)

    #expect(await environment.saveSecret("grok-key", field: "apiKey", provider: "Grok"))
    #expect(environment.runtime.isMonitoring)
    await environment.stop()
}

@Test @MainActor func stopDuringLaunchCannotMarkStartupComplete() async throws {
    let secrets = DelayedStartupSecrets()
    let fixture = TestEnvironment()
    let environment = fixture.make(
        secretStore: secrets,
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true))
    var requests = secrets.requests.makeAsyncIterator()
    let starting = Task { await environment.start() }

    #expect(await requests.next() == "iris.apikey.Meta")
    await environment.stop()
    await secrets.completeLoad(key: "iris.apikey.Meta")
    #expect(await requests.next() == "iris.secret.Meta.sessionId")
    await secrets.completeLoad(key: "iris.secret.Meta.sessionId")
    await starting.value

    #expect(!environment.hasFinishedInitialStartup)
    #expect(!environment.runtime.isStarted)
    #expect(!environment.runtime.isMonitoring)
}
