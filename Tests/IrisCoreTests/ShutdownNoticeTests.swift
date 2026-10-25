import IrisProviders
import Testing

@testable import IrisCore

@Test func refusedPressDuringFailureCleanupKeepsTheRealTerminalError() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = HangingCancelClient(cancel: gate)
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock))
    #expect(await loop.pressBegan())
    let states = await loop.states()
    client.channel.continuation.yield(.error(TranscriptionError.auth("original authentication failure")))
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error("original authentication failure") { return }
    }
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    let terminal = await loop.snapshot
    #expect(await loop.pressBegan() == false)
    await loop.reportBusyPress()
    let busy = await loop.snapshot
    #expect(busy.lastError == "original authentication failure")
    #expect(busy.lastTerminal == terminal.lastTerminal)
    #expect(busy.terminalRevision == terminal.terminalRevision)
    gate.release()
    #expect(await loop.waitForCleanup() == .clean)
    #expect((await loop.snapshot).lastError == "original authentication failure")
}

@Test func hotkeyEOFDuringStartupCancelsWithoutInsertingALateResult() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = ControlledClient(start: gate)
    let stopped = AsyncStream.makeStream(of: Void.self)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) }, config: ProviderConfiguration(provider: .mock),
        pressEnder: { stopped.continuation.yield(()) })
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    feed.finish()
    try await AsyncDeadline.run(seconds: 1) {
        var stops = stopped.stream.makeAsyncIterator()
        _ = await stops.next()
    }
    #expect(!gate.isReleased)
    #expect(await loop.isPressActive == false)
    gate.release()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(inserter.inserts.isEmpty)
    #expect(await loop.requiresRestart == false)
}

@Test func repeatedStopKeepsAQuarantinedCleanupTimedOut() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = HangingCancelClient(cancel: gate)
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: client, shutdownTimeout: 0.01) },
        config: ProviderConfiguration(provider: .mock), shutdownTimeout: 0.05)
    #expect(await loop.pressBegan())
    #expect(await loop.stop() == .timedOut)
    #expect(await loop.stop() == .timedOut)
    #expect(await loop.requiresRestart)
    #expect(await loop.pressBegan() == false)
}

@Test func cancellationPublicationIsOwnedByTheShutdownDeadline() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock), shutdownTimeout: 0.05,
        onCancelledTake: { _, _ in await gate.wait() })
    #expect(await loop.pressBegan())
    #expect(await loop.stop() == .timedOut)
    #expect(!gate.isReleased)
    #expect(await loop.requiresRestart)
    #expect(await loop.pressBegan() == false)
}
