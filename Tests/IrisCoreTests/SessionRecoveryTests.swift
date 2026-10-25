import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func nonCooperativeCancelReturnsBeforeManualRelease() async {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let service = TranscriptionService(client: HangingCancelClient(cancel: gate), shutdownTimeout: 0.05)
    let result = await service.cancel()
    #expect(result == .timedOut)
    #expect(!gate.isReleased)
    #expect(await service.requiresRestart)
}

@Test func cancelledCallerStillAllowsCleanShutdown() async {
    let service = TranscriptionService(client: MockTranscriptionClient(), shutdownTimeout: 0.5)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await service.cancel()
    }
    #expect(await task.value == .clean)
    #expect(await service.requiresRestart == false)
}

@Test func blockedStartupLatchesRestartInsteadOfPausingForever() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = ControlledClient(start: gate)
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: client, shutdownTimeout: 0.05) },
        config: ProviderConfiguration(provider: .mock), shutdownTimeout: 0.1)
    let starting = Task { await loop.pressBegan() }
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    #expect(await loop.stop() == .timedOut)
    #expect(!gate.isReleased)
    #expect(await loop.snapshot.requiresRestart)
    await loop.pressBegan()
    #expect(client.starts.get() == 1)
    gate.release()
    _ = await starting.value
    await loop.pressBegan()
    #expect(client.starts.get() == 1)
}

@Test func pendingOldAudioMustRetireBeforeTheNextTake() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let first = ControlledClient(send: gate, failSend: true)
    let second = MockTranscriptionClient()
    let services = TestValue(0)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1, -1])]), inserter: inserter,
        makeService: { _ in
            let index = services.update {
                $0 += 1
                return $0
            }
            return TranscriptionService(client: index == 1 ? first : second)
        }, config: ProviderConfiguration(provider: .mock))
    await loop.pressBegan()
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    let stopping = Task { await loop.stop() }
    try await AsyncDeadline.run(seconds: 5) {
        var cancellation = first.cancels.stream.makeAsyncIterator()
        _ = await cancellation.next()
    }
    await loop.pressBegan()
    #expect(services.get() == 1)
    gate.release()
    let stopped = try await AsyncDeadline.run(seconds: 5) { await stopping.value }
    #expect(stopped == .clean)
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(inserter.inserts == ["hello world "])
}

@Test func audioFailureStopsCaptureOnceBeforeReportingIdle() async throws {
    let stops = TestValue(0)
    let client = ControlledClient(failSend: true)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1, -1])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock), pressEnder: { stops.update { $0 += 1 } })
    let states = await loop.states()
    await loop.pressBegan()
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states {
            if case .error = state { return }
        }
    }
    #expect(stops.get() == 1)
    client.channel.continuation.yield(.final("late success"))
    await loop.pressEnded()
    #expect(stops.get() == 1)
    #expect(inserter.inserts.isEmpty)
}

@Test(arguments: [ProviderID.meta, .grok])
func liveProviderErrorStopsCaptureBeforeKeyRelease(provider: ProviderID) async throws {
    let ack = provider == .meta ? #"{"sessionId":"live"}"# : #"{"type":"transcript.created"}"#
    let transport = TestTransport(serverFrames: [Data(ack.utf8)], deliverCount: 1)
    let client: any TranscriptionClient =
        provider == .meta
        ? MetaVoiceTranscribeClient(transport: transport) : GrokVoiceTranscribeClient(transport: transport)
    let stops = TestValue(0)
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: provider, values: ["apiKey": "fixture", "audioEncoding": "PCM_16KHZ"]),
        pressEnder: { stops.update { $0 += 1 } })
    let states = await loop.states()
    await loop.pressBegan()
    transport.emit(#"{"type":"error","code":429,"message":"quota exhausted"}"#)
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states { if case .error = state { return } }
    }
    #expect(stops.get() == 1)
    #expect(transport.didClose)
    await loop.pressEnded()
    #expect(stops.get() == 1)
}

@Test func uiSnapshotsKeepTerminalNoticesAcrossCoalescedIdle() async throws {
    let client = ControlledClient(failSend: true)
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1, -1])]),
        makeService: { _ in TranscriptionService(client: client) }, config: ProviderConfiguration(provider: .mock))
    let snapshots = await loop.snapshots()
    let states = await loop.states()
    await loop.pressBegan()
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states { if case .error = state { return } }
    }
    await loop.pressEnded()
    var iterator = snapshots.makeAsyncIterator()
    let latest = await iterator.next()
    #expect(latest?.state == .idle)
    #expect(latest?.lastError == "audio failure")
    #expect(latest?.lastTerminal == .error("audio failure"))
}

@Test func aLateConnectIsClosedBeforeShutdownReportsSuccess() async throws {
    final class LateTransport: ByteStream, Sendable {
        let gate = ManualGate()
        let open = TestValue(false)
        let closed = AsyncStream.makeStream(of: Void.self)
        func connect() async throws {
            await gate.wait()
            open.update { $0 = true }
        }
        func close() async {
            open.update { $0 = false }
            closed.continuation.yield(())
        }
        func write(_ message: TransportMessage) async throws {}
        func messages() -> AsyncThrowingStream<TransportMessage, Error> { AsyncThrowingStream { $0.finish() } }
    }
    let transport = LateTransport()
    let watchdog = transport.gate.watchdog()
    defer {
        watchdog.cancel()
        transport.gate.release()
    }
    let service = TranscriptionService(client: GrokVoiceTranscribeClient(transport: transport))
    let starting = Task {
        try await service.start(config: ProviderConfiguration(provider: .grok, values: ["apiKey": "fixture"]))
    }
    try await AsyncDeadline.run(seconds: 5) { await transport.gate.waitUntilEntered() }
    let stopping = Task { await service.cancel() }
    try await AsyncDeadline.run(seconds: 5) {
        var closed = transport.closed.stream.makeAsyncIterator()
        _ = await closed.next()
    }
    transport.gate.release()
    let stopped = try await AsyncDeadline.run(seconds: 5) { await stopping.value }
    #expect(stopped == .clean)
    switch await starting.result {
    case .failure(let error):
        #expect(error is CancellationError)
    case .success:
        Issue.record("Cancelled start should throw CancellationError")
    }
    #expect(transport.open.get() == false)
}

@Test func eventOverflowFailsTheTakeInsteadOfDroppingResults() async throws {
    let transport = TestTransport(serverFrames: [Data(#"{"type":"transcript.created"}"#.utf8)], deliverCount: 1)
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: ProviderConfiguration(provider: .grok, values: ["apiKey": "fixture"]))
    // Deliberately leave events() unconsumed to exercise backpressure failure.
    for _ in 0..<1000 {
        transport.emit(#"{"type":"transcript.partial","text":"words","is_final":false}"#)
    }
    do {
        try await AsyncDeadline.run(seconds: 10) { try await client.endAudio() }
        Issue.record("Overflow must fail explicitly")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .network)
        #expect(failure.message.contains("fell behind"))
    } catch is CancellationError {
        // The overflow failure can race endAudio's write chain: cancelling
        // the pending writes surfaces as CancellationError first. The
        // session has already failed; a second endAudio returns the
        // terminal failure the overflow produced.
        do {
            try await client.endAudio()
            Issue.record("Overflow must fail explicitly")
        } catch let failure as TranscriptionError {
            #expect(failure.kind == .network)
            #expect(failure.message.contains("fell behind"))
        }
    }
    await client.cancel()
}

private struct CapCodec: SpeechSessionCodec {
    var handshake: TransportMessage? { nil }
    var endMarker: TransportMessage { .text("end") }
    var completesOnClose: Bool { false }
    func isReady(_ message: TransportMessage) -> Bool {
        if case .text = message { return true }
        return false
    }
    func decode(_ message: TransportMessage) -> TranscriptionEvent? { nil }
}

@Test func sessionBeyondTheDurationCapFailsExplicitly() async throws {
    // A Meta-shaped ACK keeps the receive stream open past readiness.
    let transport = TestTransport(serverFrames: [Data(#"{"sessionId":"s1"}"#.utf8)])
    let driver = SessionDriver(transport: transport, ackTimeout: 5, finishTimeout: 5, maxSessionSeconds: 0)
    let checking = Task {
        do {
            try await driver.start(codec: CapCodec())
            do {
                try await driver.sendAudio(PCMFrame(samples: [1, -1]))
                Issue.record("Audio past the session cap must fail")
            } catch let failure as TranscriptionError {
                #expect(failure.kind == .streamLimit)
            }
            await #expect(
                throws: TranscriptionError(kind: .invalidState, message: "Audio sent outside an active session.")
            ) {
                try await driver.sendAudio(PCMFrame(samples: [1, -1]))
            }
            #expect(transport.messagesWritten.isEmpty)
        } catch {
            await driver.cancel()
            throw error
        }
        await driver.cancel()
        #expect(transport.didClose)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test(arguments: [0.0, 120.0, SessionDriver.maxSessionSeconds])
func sessionCapMatchesItsUserFacingLimit(maxDuration: Double) async throws {
    // Advance an injected monotonic clock through real, nonnegative budgets,
    // including the production default, without a minutes-long sleep.
    let transport = TestTransport(serverFrames: [Data(#"{"sessionId":"cap"}"#.utf8)])
    let clock = TestValue(0.0)
    let driver = SessionDriver(
        transport: transport, ackTimeout: 5, finishTimeout: 5, maxSessionSeconds: maxDuration,
        uptime: { clock.get() })
    let checking = Task {
        do {
            try await driver.start(codec: CapCodec())
            clock.update { $0 = maxDuration + 1 }
            let failure: TranscriptionError
            do {
                try await driver.sendAudio(PCMFrame(samples: [1, -1]))
                Issue.record("The expired session budget must reject audio")
                await driver.cancel()
                return
            } catch let thrown as TranscriptionError {
                failure = thrown
            }
            #expect(failure.kind == .streamLimit)
            let minutes = Int(maxDuration / 60)
            #expect(
                failure.message == "Speech session reached the \(minutes)-minute limit. Start a new take to continue.")

            var emitted: [TranscriptionEvent] = []
            do {
                for try await event in driver.events() { emitted.append(event) }
                Issue.record("The duration cap must also fail the event stream")
            } catch let streamed as TranscriptionError {
                #expect(streamed == failure)
            }
            #expect(emitted == [.error(failure)])
            await #expect(throws: failure) { try await driver.endAudio() }
            #expect(transport.messagesWritten.isEmpty)
        } catch {
            await driver.cancel()
            throw error
        }
        await driver.cancel()
        #expect(transport.didClose)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}
