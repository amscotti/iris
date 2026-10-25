import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private let lifecycleConfig = ProviderConfiguration(provider: .mock)

@Test(arguments: [HotkeyConfiguration.Mode.hold, .toggle])
func hotkeyStopDuringStartupStopsCaptureBeforeTheAck(mode: HotkeyConfiguration.Mode) async throws {
    let startup = ManualGate()
    let watchdog = startup.watchdog()
    defer {
        watchdog.cancel()
        startup.release()
    }
    let client = ControlledClient(start: startup)
    let stopped = AsyncStream.makeStream(of: Void.self)
    let inserter = RecordingInserter()
    var settings = AppSettings.defaults
    settings.hotkey.mode = mode
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1, -1])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) }, settings: settings, config: lifecycleConfig,
        pressEnder: { stopped.continuation.yield(()) })
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await AsyncDeadline.run(seconds: 5) { await startup.waitUntilEntered() }
    if mode == .toggle { feed.emit(.released) }
    feed.emit(mode == .hold ? .released : .pressed)
    try await AsyncDeadline.run(seconds: 1) {
        var stops = stopped.stream.makeAsyncIterator()
        _ = await stops.next()
    }
    #expect(!startup.isReleased)
    #expect(await loop.isPressActive == false)
    startup.release()
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(inserter.inserts.isEmpty)
    #expect(await loop.requiresRestart == false)
}

private final class ParkedEndClient: TranscriptionClient, Sendable {
    let end: ManualGate
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    init(end: ManualGate) { self.end = end }
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        await end.wait()
        try Task.checkCancellation()
        channel.continuation.yield(.final("first take"))
        channel.continuation.finish()
    }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test(arguments: [HotkeyConfiguration.Mode.hold, .toggle])
func busyHotkeyEdgesAreRejectedBeforeFinalizationCompletes(mode: HotkeyConfiguration.Mode) async throws {
    let end = ManualGate()
    let watchdog = end.watchdog()
    defer {
        watchdog.cancel()
        end.release()
    }
    let first = ParkedEndClient(end: end)
    let creations = TestValue(0)
    let inserter = RecordingInserter()
    var settings = AppSettings.defaults
    settings.hotkey.mode = mode
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in
            let index = creations.update {
                $0 += 1
                return $0
            }
            return TranscriptionService(client: index == 1 ? first : MockTranscriptionClient())
        }, settings: settings, config: lifecycleConfig)
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await waitForRecording(loop)
    if mode == .toggle { feed.emit(.released) }
    feed.emit(mode == .hold ? .released : .pressed)
    if mode == .toggle { feed.emit(.released) }
    try await AsyncDeadline.run(seconds: 5) { await end.waitUntilEntered() }
    let states = await loop.states()
    feed.emit(.pressed)
    feed.emit(.cancelled)
    feed.emit(.released)
    try await AsyncDeadline.run(seconds: 1) {
        for await state in states where state == .error(DictationOrchestrator.busyMessage) { return }
    }
    #expect(!end.isReleased)
    #expect(creations.get() == 1)
    end.release()
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(creations.get() == 1)
    #expect(inserter.inserts == ["first take "])
    let fresh: [HotkeyEvent] = mode == .hold ? [.pressed, .released] : [.pressed, .released, .pressed, .released]
    try await runRecordingHotkeyScript(fresh, on: loop)
    #expect(creations.get() == 2)
    #expect(inserter.inserts == ["first take ", "hello world "])
}

private enum BlockedCleanup: Sendable { case cancellation, audioDelivery }

/// A transport wedged in both directions: the parked write ignores
/// cancellation and cancel parks too. Only this shape legitimately outruns
/// the cleanup deadline — a real transport aborts its writes when
/// cancelled — so the quarantine assertion models a genuinely dead socket.
private final class WedgedDeliveryClient: TranscriptionClient, Sendable {
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    private let gate = ManualGate()
    var isReleased: Bool { gate.isReleased }
    func waitUntilParked() async { await gate.waitUntilEntered() }
    func release() { gate.release() }
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws { await gate.wait() }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {}
    func cancel() async { await gate.wait() }
}

@Test(arguments: [BlockedCleanup.cancellation, .audioDelivery])
private func liveFailureKeepsCleanupQuarantinedUntilRestart(blocked: BlockedCleanup) async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    let wedged = WedgedDeliveryClient()
    defer {
        watchdog.cancel()
        gate.release()
        wedged.release()
    }
    let cancelling = HangingCancelClient(cancel: gate)
    let client: any TranscriptionClient = blocked == .cancellation ? cancelling : wedged
    let service = TranscriptionService(client: client, shutdownTimeout: 0.05)
    let creations = TestValue(0)
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1, -1])]),
        makeService: { _ in
            creations.update { $0 += 1 }
            return service
        },
        config: lifecycleConfig, shutdownTimeout: 0.2)
    await loop.pressBegan()
    if blocked == .audioDelivery {
        try await AsyncDeadline.run(seconds: 5) { await wedged.waitUntilParked() }
    }
    let states = await loop.states()
    let failure = TranscriptionEvent.error(TranscriptionError(kind: .network, message: "live failure"))
    if blocked == .cancellation {
        cancelling.channel.continuation.yield(failure)
    } else {
        wedged.channel.continuation.yield(failure)
    }
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error("live failure") { return }
    }
    if blocked == .cancellation {
        try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    }
    #expect(await loop.pressBegan() == false)
    #expect(await loop.waitForCleanup() == .timedOut)
    #expect(await loop.requiresRestart)
    if blocked == .cancellation {
        #expect(!gate.isReleased)
    } else {
        #expect(!wedged.isReleased)
    }
    #expect(await loop.pressBegan() == false)
    #expect(creations.get() == 1)
}

@Test func silentCompletionStillEnforcesTheProviderCleanupDeadline() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = HangingCancelClient(cancel: gate)
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        makeService: { _ in TranscriptionService(client: client, shutdownTimeout: 0.05) },
        config: lifecycleConfig, shutdownTimeout: 0.2)
    await loop.pressBegan()
    client.channel.continuation.yield(.final(""))
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    #expect(await loop.waitForCleanup() == .timedOut)
    let snapshot = await loop.snapshot
    #expect(snapshot.requiresRestart)
    #expect(snapshot.lastError == TranscriptionService.restartMessage)
    #expect(snapshot.lastTerminal == nil)
}

@Test func aCleanLiveFailureRetiresBeforeTheNextTakeAndKeepsItsNotice() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let first = HangingCancelClient(cancel: gate)
    let creations = TestValue(0)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in
            let index = creations.update {
                $0 += 1
                return $0
            }
            return TranscriptionService(client: index == 1 ? first : MockTranscriptionClient())
        }, config: lifecycleConfig)
    await loop.pressBegan()
    let states = await loop.states()
    first.channel.continuation.yield(.error(TranscriptionError(kind: .network, message: "live failure")))
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error("live failure") { return }
    }
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    #expect(await loop.pressBegan() == false)
    gate.release()
    #expect(await loop.waitForCleanup() == .clean)
    #expect((await loop.snapshot).lastError == "live failure")
    #expect(await loop.pressBegan())
    await loop.pressEnded()
    #expect(inserter.inserts == ["hello world "])
    #expect(creations.get() == 2)
    #expect(await loop.requiresRestart == false)
}

@Test func aBusyPressDuringRewriteDoesNotStartADelayedTake() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let prompt = PromptDefinition(template: "Rewrite")
    var settings = AppSettings.defaults
    settings.prompts = [prompt]
    settings.selectedPromptID = prompt.id
    let creations = TestValue(0)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in
            creations.update { $0 += 1 }
            return TranscriptionService(client: MockTranscriptionClient())
        }, settings: settings, config: lifecycleConfig,
        rewriteRunner: { _, _ in
            await gate.wait()
            return "rewritten"
        })
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await waitForRecording(loop)
    feed.emit(.released)
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    let published = await loop.snapshot
    #expect(published.state == .enhancing)
    #expect(published.lastTerminal == .final("hello world"))
    feed.emit(.pressed)
    feed.emit(.cancelled)
    feed.emit(.released)
    try? await Task.sleep(nanoseconds: 200_000_000)
    // A busy press during the rewrite must not replace the published
    // pre-rewrite final, and no delayed take may start from these edges.
    let during = await loop.snapshot
    #expect(during.lastTerminal == .final("hello world"))
    #expect(during.lastError == nil)
    #expect(creations.get() == 1)
    gate.release()
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(creations.get() == 1)
    #expect(inserter.inserts == ["rewritten "])
}

@Test func cancellingAPressCallerAlsoCancelsItsOwnedStartup() async throws {
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
        makeService: { _ in TranscriptionService(client: client) }, config: lifecycleConfig,
        pressEnder: { stopped.continuation.yield(()) })
    let starting = Task { await loop.pressBegan() }
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    starting.cancel()
    try await AsyncDeadline.run(seconds: 1) {
        var stops = stopped.stream.makeAsyncIterator()
        _ = await stops.next()
    }
    #expect(!gate.isReleased)
    gate.release()
    #expect(await starting.value == false)
    #expect(await loop.waitForCleanup() == .clean)
    #expect(await loop.isPressActive == false)
    #expect(inserter.inserts.isEmpty)
}

@Test func hotkeyEOFAwaitsLiveErrorCaptureDrainAndCleanup() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = ControlledClient()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: client) },
        config: lifecycleConfig, pressEnder: { await gate.wait() })
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await waitForRecording(loop)
    client.channel.continuation.yield(.error(TranscriptionError(kind: .network, message: "live failure")))
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    feed.finish()
    let earlyReturn = await AsyncDeadline.shutdown(seconds: 0.05) { await running.value }
    #expect(earlyReturn == .timedOut)
    #expect(!gate.isReleased)
    gate.release()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(await loop.isPressActive == false)
    #expect(await loop.requiresRestart == false)
    #expect((await loop.snapshot).lastError == "live failure")
}

@Test func cancellingAFinalizationCallerPreventsItsLateRewriteFromInserting() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let prompt = PromptDefinition(template: "Rewrite")
    var settings = AppSettings.defaults
    settings.prompts = [prompt]
    settings.selectedPromptID = prompt.id
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: settings, config: lifecycleConfig,
        rewriteRunner: { _, _ in
            await gate.wait()
            return "late rewrite"
        })
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    let states = await loop.states()
    ending.cancel()
    try await AsyncDeadline.run(seconds: 1) {
        for await state in states where state == .idle { return }
    }
    #expect(!gate.isReleased)
    #expect(await loop.isPressActive == false)
    gate.release()
    await ending.value
    #expect(await loop.waitForCleanup() == .clean)
    #expect(inserter.inserts.isEmpty)
}
