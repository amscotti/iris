import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Client whose session open always fails, for the start-failure path.
final class FailingStartClient: TranscriptionClient, @unchecked Sendable {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func start(config: ProviderConfiguration) async throws {
        throw error
    }

    func sendAudio(_ frame: PCMFrame) async throws {}

    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func endAudio() async throws {}

    func cancel() async {}
}

private func serviceConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

/// Waits for a collection task, failing the test instead of hanging the
/// suite forever when the expected terminal state never arrives.
private func waitForStates(_ task: Task<[PushToTalkState], Never>) async -> [PushToTalkState] {
    guard let seen = try? await AsyncDeadline.run(seconds: 5, operation: { await task.value }) else {
        Issue.record("state collection timed out")
        return []
    }
    return seen
}

private func collectServiceStates(_ service: TranscriptionService, count: Int) async -> Task<
    [PushToTalkState], Never
> {
    let stream = await service.states()
    return Task {
        var seen: [PushToTalkState] = []
        for await state in stream {
            seen.append(state)
            if seen.count >= count { break }
        }
        return seen
    }
}

@Test func startFailureEmitsErrorThenIdleAndRethrows() async throws {
    let service = TranscriptionService(
        client: FailingStartClient(error: TranscriptionError.auth("bad key")))
    let collected = await collectServiceStates(service, count: 3)
    do {
        try await service.start(config: serviceConfig())
        Issue.record("Expected start to throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
    }
    let seen = await waitForStates(collected)
    #expect(seen.first == .idle)
    #expect(seen.contains(.error("bad key")))
    #expect(seen.last == .idle)
    #expect(await service.lastFinal == nil)
}

@Test func audioOutsideARecordingSessionThrows() async {
    let service = TranscriptionService(client: MockTranscriptionClient())
    await #expect(
        throws: TranscriptionError(kind: .invalidState, message: "Audio appended outside a recording session.")
    ) {
        try await service.appendAudio(PCMFrame(samples: [1, -1]))
    }
}

@Test func finalMidStreamStopsReadingLateEvents() async throws {
    let client = ScriptedClient(events: [.final("done"), .partial("late")])
    let service = TranscriptionService(client: client)
    let collected = await collectServiceStates(service, count: 4)
    try await service.start(config: serviceConfig())
    await service.finish()
    #expect(await service.lastFinal == "done")
    let seen = await waitForStates(collected)
    #expect(seen.contains(.final("done")))
    #expect(!seen.contains(.partial("late")))
    #expect(seen.last == .idle)
}

@Test func finishTransportErrorSurfacesUnknownFailure() async throws {
    let transportError = NSError(
        domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    let client = ScriptedClient(events: [.partial("half")], terminalError: transportError)
    let service = TranscriptionService(client: client)
    let collected = await collectServiceStates(service, count: 5)
    try await service.start(config: serviceConfig())
    await service.finish()
    let seen = await waitForStates(collected)
    #expect(seen.contains(.error("boom")))
    #expect(seen.last == .idle)
    #expect(await service.lastFinal == nil)
}

@Test func speechOnsetAloneChangesNothing() async throws {
    let client = ScriptedClient(events: [.speechStarted, .final("done")])
    let service = TranscriptionService(client: client)
    try await service.start(config: serviceConfig())
    await service.finish()
    #expect(await service.lastFinal == "done")
    #expect(await service.currentState == .idle)
}

@Test func errorEventFailsTheSession() async throws {
    let client = ScriptedClient(events: [
        .partial("half"), .error(TranscriptionError(kind: .network, message: "down")),
    ])
    let service = TranscriptionService(client: client)
    let collected = await collectServiceStates(service, count: 5)
    try await service.start(config: serviceConfig())
    await service.finish()
    let seen = await waitForStates(collected)
    #expect(seen.contains(.partial("half")))
    #expect(seen.contains(.error("down")))
    #expect(seen.last == .idle)
    #expect(await service.lastFinal == nil)
}

@Test func turnBoundaryWithoutAPartialSurfacesTheNoSpeechTerminalState() async throws {
    let client = ScriptedClient(events: [.speechComplete(turnId: "t-1", transcript: "")])
    let service = TranscriptionService(client: client, completion: .turnComplete)
    // A blank completion still reaches observers — it is the "no speech"
    // signal: idle, recording, final(""), idle. Only real text is retained.
    let collected = await collectServiceStates(service, count: 4)
    try await service.start(config: serviceConfig())
    await service.finish()
    #expect(await service.lastFinal == nil)
    let seen = await waitForStates(collected)
    #expect(seen.contains(.final("")))
    #expect(seen.last == .idle)
}

@Test func aTextlessBoundaryDoesNotRepeatThePreviousTurn() async throws {
    let client = ScriptedClient(events: [
        .partial("hello"),
        .speechComplete(turnId: "t-1", transcript: ""),
        .speechComplete(turnId: "t-2", transcript: ""),
    ])
    let service = TranscriptionService(client: client, completion: .turnComplete)
    try await service.start(config: serviceConfig())
    let outcome = await service.finish()
    // The first textless boundary legitimately uses the current partial; the
    // second must not reuse it again.
    #expect(outcome == .completed("hello"))
}
