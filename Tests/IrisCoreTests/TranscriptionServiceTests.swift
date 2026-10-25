import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Scriptable client: replays a fixed event list on finish.
final class ScriptedClient: TranscriptionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [TranscriptionEvent]
    private let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    private let terminalError: Error?
    private var frames = 0

    init(events: [TranscriptionEvent], terminalError: Error? = nil) {
        self.script = events
        self.terminalError = terminalError
    }

    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {
        incrementFrames()
    }

    private func incrementFrames() {
        lock.lock()
        frames += 1
        lock.unlock()
    }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        let events = self.script
        let terminalError = self.terminalError
        let continuation = channel.continuation
        for event in events { continuation.yield(event) }
        if let terminalError {
            continuation.finish(throwing: terminalError)
        } else {
            continuation.finish()
        }
    }

    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }

    var frameCount: Int {
        lock.lock()
        let count = frames
        lock.unlock()
        return count
    }
}

private func mockConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

private func collectStates(
    _ service: TranscriptionService, count: Int
) async -> Task<[PushToTalkState], Never> {
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

@Test func cancelPreservesACompletedTerminalOutcome() async throws {
    let service = TranscriptionService(client: MockTranscriptionClient())
    try await service.start(config: mockConfig())
    try await service.appendAudio(PCMFrame(samples: [1000, -1000]))
    let outcome = await service.finish()
    guard case .completed = outcome else {
        Issue.record("Expected completion, got \(outcome)")
        return
    }
    _ = await service.cancel()
    #expect(await service.terminalOutcome == outcome)
    _ = await service.cancel()
    #expect(await service.terminalOutcome == outcome)
}

@Test func fullPressEmitsPartialsThenFinal() async throws {
    let client = MockTranscriptionClient()
    let service = TranscriptionService(client: client)
    let collected = await collectStates(service, count: 7)
    try await service.start(config: mockConfig())
    try await service.appendAudio(PCMFrame(samples: [1000, -1000]))
    await service.finish()
    let seen = await collected.value
    #expect(seen.first == .idle)
    #expect(seen.contains(.recording(level: 0)))
    #expect(seen.contains(.partial("hello")))
    #expect(seen.contains(.final("hello world")))
    #expect(seen.last == .idle)
    #expect(client.receivedFrameCount == 1)
}

@Test func failureReturnsToIdleAndNextPressRetries() async throws {
    let client = MockTranscriptionClient()
    client.finishError = TranscriptionError(kind: .network, message: "dropped")
    let service = TranscriptionService(client: client)
    let first = await collectStates(service, count: 4)
    try await service.start(config: mockConfig())
    await service.finish()
    let seen = await first.value
    #expect(seen.contains(.error("dropped")))
    #expect(seen.last == .idle)

    client.finishError = nil
    let second = await collectStates(service, count: 6)
    try await service.start(config: mockConfig())
    await service.finish()
    let retried = await second.value
    #expect(retried.contains(.final("hello world")))
}

@Test func closeWithoutCompletionIsAnError() async throws {
    let client = ScriptedClient(events: [.partial("half a thought")])
    let service = TranscriptionService(client: client)
    let collected = await collectStates(service, count: 5)
    try await service.start(config: mockConfig())
    await service.finish()
    let seen = await collected.value
    #expect(
        !seen.contains(where: {
            if case .final = $0 { return true }
            return false
        }))
    #expect(
        seen.contains(where: {
            if case .error = $0 { return true }
            return false
        }))
    #expect(seen.last == .idle)
}

@Test func endpointingCompletesOnTurnBoundary() async throws {
    let client = ScriptedClient(events: [.partial("take out"), .speechComplete(turnId: "t-1", transcript: "")])
    let service = TranscriptionService(client: client, completion: .turnComplete)
    let collected = await collectStates(service, count: 5)
    try await service.start(config: mockConfig())
    await service.finish()
    let seen = await collected.value
    #expect(seen.contains(.final("take out")))
    #expect(seen.last == .idle)
}

@Test func pushToTalkIgnoresStrayTurnBoundaries() async throws {
    let client = ScriptedClient(events: [.partial("abc"), .speechComplete(turnId: "t-1", transcript: "")])
    let service = TranscriptionService(client: client, completion: .finalEvent)
    let collected = await collectStates(service, count: 5)
    try await service.start(config: mockConfig())
    await service.finish()
    let seen = await collected.value
    #expect(
        !seen.contains(where: {
            if case .final = $0 { return true }
            return false
        }))
    #expect(seen.last == .idle)
}

@Test func endpointingJoinsMultipleTurnsOnClose() async throws {
    let client = ScriptedClient(events: [
        .speechComplete(turnId: "1", transcript: "hello"),
        .speechComplete(turnId: "2", transcript: "world"),
    ])
    let service = TranscriptionService(client: client, completion: .turnComplete)
    let collected = await collectStates(service, count: 4)
    try await service.start(config: mockConfig())
    await service.finish()
    let seen = await collected.value
    #expect(seen.contains(.final("hello world")))
    #expect(seen.last == .idle)
    #expect(await service.lastFinal == "hello world")
}

@Test func endpointingKeepsTheTrailingPartialAfterTheLastTurn() async throws {
    let client = ScriptedClient(events: [
        .speechComplete(turnId: "1", transcript: "hello"),
        .partial("world dom"),
    ])
    let service = TranscriptionService(client: client, completion: .turnComplete)
    try await service.start(config: mockConfig())
    let outcome = await service.finish()
    // The stream closed without the final utterance's completion: its
    // trailing partial still belongs in the transcript.
    #expect(outcome == .completed("hello world dom"))
    #expect(await service.lastFinal == "hello world dom")
}

@Test func audioLevelSurfacesInRecordingState() async throws {
    let client = MockTranscriptionClient()
    let service = TranscriptionService(client: client)
    try await service.start(config: mockConfig())
    try await service.appendAudio(PCMFrame(samples: [8000, -8000, 8000, -8000]))
    let current = await service.currentState
    if case .recording(let level) = current {
        #expect(level > 0)
    } else {
        Issue.record("Expected a recording state, got \(current)")
    }
    await service.finish()
}
