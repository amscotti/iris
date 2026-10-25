import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private final class RestartLatchClient: TranscriptionClient, @unchecked Sendable {
    private let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)

    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        channel.continuation.yield(.final("completed before close"))
        channel.continuation.finish()
    }
    func cancel() async {
        // Deliberately non-cooperative: the service deadline must quarantine
        // this client rather than waiting for it forever.
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
}

@Test @MainActor func orchestratorRestartLatchAlsoSuspendsRuntimePresentation() async throws {
    let fixture = RuntimeFixture()
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports(service: { _ in
            TranscriptionService(client: RestartLatchClient(), shutdownTimeout: 0.05)
        }))
    await environment.start()
    do {
        try await fixture.beginRecordedTake(in: environment)
        fixture.keys.emit(.released)
        try await AsyncDeadline.run(seconds: 5) { @MainActor in
            while !environment.requiresRelaunch { await Task.yield() }
        }

        #expect(environment.runtime.state == .restartRequired(TranscriptionService.restartMessage))
        #expect(!environment.runtime.isMonitoring)
        #expect(environment.statusLine == "Restart Iris to resume dictation")
        #expect(fixture.inserter.targets.count == 1)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}
