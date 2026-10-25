import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

/// The capture-failure bridge: a capturer reporting device loss through the
/// installed out-of-band handler must reach the orchestrator via the
/// runtime wiring and end the take with the failure surfaced, not insert a
/// partial transcript.
@Test func parkedCaptureDecoratorForwardsFailureHandlerToBase() async throws {
    let base = RuntimeTestAudio()
    let parked = RuntimeJourneyParkedCapture(base: base, stopping: RuntimeJourneyGate())
    let received = AsyncStream.makeStream(of: String.self)
    parked.setCaptureFailureHandler { _, message in received.continuation.yield(message) }
    await base.failCapture("Capture device stopped unexpectedly")
    let message = try await AsyncDeadline.run(seconds: 2) {
        var input = received.stream.makeAsyncIterator()
        return await input.next()
    }
    #expect(message == "Capture device stopped unexpectedly")
}

@Test @MainActor func captureFailureBridgeEndsTheTakeThroughTheRuntimeWiring() async throws {
    let fixture = RuntimeFixture()
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports())
    await environment.start()
    try await fixture.beginRecordedTake(in: environment)

    await fixture.audio.failCapture("Capture device stopped unexpectedly")

    do {
        try await AsyncDeadline.run(seconds: 5) { @MainActor in
            while environment.lastDictationError == nil { await Task.yield() }
        }
    } catch {
        Issue.record("The capture failure never surfaced.")
    }
    #expect(environment.lastDictationError == "Capture device stopped unexpectedly")
    #expect(fixture.inserter.targets.isEmpty)
    #expect(!environment.runtime.requiresRestart)
    let runtime = environment.runtime
    let cleanup = try await AsyncDeadline.run(seconds: 5) { await runtime.waitForCleanup() }
    #expect(cleanup == .clean)
    await environment.stop()
}

@Test @MainActor func delayedFailureFromAnOldTakeCannotEndTheNewRuntimeTake() async throws {
    let fixture = RuntimeFixture()
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports())
    await environment.start()
    do {
        try await fixture.beginRecordedTake(in: environment)
        let firstID = try #require(await environment.runtime.orchestrator.currentTake?.id)
        await fixture.audio.failCapture("first failure", takeID: firstID)
        _ = try await AsyncDeadline.run(seconds: 5) { await environment.runtime.waitForCleanup() }

        try await fixture.beginRecordedTake(in: environment)
        let secondID = try #require(await environment.runtime.orchestrator.currentTake?.id)
        #expect(secondID != firstID)
        await fixture.audio.failCapture("delayed first failure", takeID: firstID)
        #expect(await environment.runtime.orchestrator.isPressActive)
        #expect(environment.lastDictationError == nil)

        await fixture.audio.failCapture("second failure", takeID: secondID)
        _ = try await AsyncDeadline.run(seconds: 5) { await environment.runtime.waitForCleanup() }
        #expect(environment.lastDictationError == "second failure")
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}
