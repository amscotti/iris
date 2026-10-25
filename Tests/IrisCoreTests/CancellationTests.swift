import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Controlled suspension without clocks, hardware, or live network access.
private final class SuspensionPoint: Sendable {
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let release: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let entry = AsyncStream.makeStream(of: Void.self)
        entered = entry.stream
        enteredContinuation = entry.continuation
        let exit = AsyncStream.makeStream(of: Void.self)
        release = exit.stream
        releaseContinuation = exit.continuation
    }

    func wait() async {
        enteredContinuation.yield(())
        for await _ in release { break }
    }

    func resume() { releaseContinuation.finish() }
}

private final class DelayedClient: TranscriptionClient, Sendable {
    let startPoint = SuspensionPoint()
    let finishEntered: AsyncStream<Void>
    private let finishSignal: AsyncStream<Void>.Continuation
    private let stream: AsyncThrowingStream<TranscriptionEvent, Error>
    let continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation

    init() {
        let signal = AsyncStream.makeStream(of: Void.self)
        finishEntered = signal.stream
        finishSignal = signal.continuation
        let result = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
        stream = result.stream
        continuation = result.continuation
    }

    func start(config: ProviderConfiguration) async throws { await startPoint.wait() }
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { stream }
    func endAudio() async throws {
        finishSignal.yield(())
    }
    // Deliberately non-cooperative: late callbacks must still be rejected.
    func cancel() async {}
}

@Test func cancelledServiceStartCannotBecomeRecordingLater() async {
    let client = DelayedClient()
    let service = TranscriptionService(client: client)
    let starting = Task { try await service.start(config: ProviderConfiguration(provider: .mock)) }
    var entered = client.startPoint.entered.makeAsyncIterator()
    _ = await entered.next()
    await service.cancel()
    client.startPoint.resume()
    await #expect(throws: CancellationError.self) { try await starting.value }
    #expect(await service.currentState == .idle)
    #expect(await service.lastFinal == nil)
}

@Test func cancelledServiceIgnoresLateCompletion() async throws {
    let client = DelayedClient()
    client.startPoint.resume()
    let service = TranscriptionService(client: client)
    try await service.start(config: ProviderConfiguration(provider: .mock))
    let finishing = Task { await service.finish() }
    var entered = client.finishEntered.makeAsyncIterator()
    _ = await entered.next()
    await service.cancel()
    client.continuation.yield(.final("must not insert"))
    client.continuation.finish()
    _ = await finishing.value
    #expect(await service.lastFinal == nil)
    #expect(await service.currentState == .idle)
}

@Test func cancelledCaptureStartupCannotOpenAProviderSession() async {
    let point = SuspensionPoint()
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter, makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock),
        pressStarter: {
            await point.wait()
            return nil
        })
    let starting = Task { await loop.pressBegan() }
    var entered = point.entered.makeAsyncIterator()
    _ = await entered.next()
    await loop.stop()
    point.resume()
    _ = await starting.value
    #expect(client.startCallCount == 0)
    #expect(inserter.inserts.isEmpty)
    #expect(await loop.isPressActive == false)
}

@Test func cancellationDuringRewriteNeverTypesTheLateReply() async {
    let point = SuspensionPoint()
    let prompt = PromptDefinition(template: "Clean up")
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: AppSettings(prompts: [prompt], selectedPromptID: prompt.id),
        config: ProviderConfiguration(provider: .mock),
        rewriteRunner: { _, _ in
            await point.wait()
            return "late reply"
        })
    await loop.pressBegan()
    let finishing = Task { await loop.pressEnded() }
    var entered = point.entered.makeAsyncIterator()
    _ = await entered.next()
    await loop.stop()
    point.resume()
    await finishing.value
    #expect(inserter.inserts.isEmpty)
    #expect(await loop.currentState == .idle)
}

@Test func terminatedSubscriptionsAreRemoved() async {
    let service = TranscriptionService(client: MockTranscriptionClient())
    #expect(await service.subscriberCount == 0)
    do {
        let stream = await service.states()
        #expect(await service.subscriberCount == 1)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        // Dropping the iterator terminates the stream; removal hops
        // off-actor, so poll briefly.
        _ = iterator
    }
    let deadline = Date().addingTimeInterval(10)
    while await service.subscriberCount != 0, Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(await service.subscriberCount == 0)
}

@Test func cancelledHotkeyLoopDoesNotFinalizeADanglingPress() async {
    struct Input: HotkeyMonitoring {
        let stream: AsyncStream<HotkeyEvent>
        func events() -> AsyncStream<HotkeyEvent> { stream }
    }
    let events = AsyncStream.makeStream(of: HotkeyEvent.self)
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter, makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock))
    let states = await loop.states()
    let worker = Task { await loop.run(hotkey: Input(stream: events.stream)) }
    events.continuation.yield(.pressed)
    for await state in states {
        if case .recording = state { break }
    }
    worker.cancel()
    await worker.value
    #expect(client.finishCallCount == 0)
    #expect(inserter.inserts.isEmpty)
    #expect(await loop.currentState == .idle)
}
