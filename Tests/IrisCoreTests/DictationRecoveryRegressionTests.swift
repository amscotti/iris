import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Regression coverage for dictation-orchestration invariants:
/// quick-tap cancel, rewrite trailing idle, restart cleanup, and empty-final uniformity.

func regressionConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

@Test func releaseDuringStartupCancelsInsteadOfResurrecting() async {
    let point = ManualGate()
    let watchdog = point.watchdog()
    defer {
        watchdog.cancel()
        point.release()
    }
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: regressionConfig(),
        pressStarter: {
            await point.wait()
            return nil
        })
    let starting = Task { await loop.pressBegan() }
    await point.waitUntilEntered()
    // End while startup is still blocked. Ending runs stop() (which nils the
    // take synchronously) while the starter is parked; releasing afterwards
    // lets both sides retire cleanly instead of deadlocking on the gate.
    let ending = Task { await loop.pressEnded() }
    // Release only once stop() has actually cleared the take; a fixed sleep
    // could let a slow runner resume the starter first.
    let deadline = Date().addingTimeInterval(10)
    while await loop.isPressActive, Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    point.release()
    _ = await starting.value
    await ending.value
    #expect(client.startCallCount == 0)
    #expect(inserter.inserts.isEmpty)
    #expect(await loop.isPressActive == false)
    #expect(await loop.currentState == .idle)
}

@Test func rewriteSuccessEndsAtIdle() async {
    let chosen = PromptDefinition(template: "Clean up")
    var settings = AppSettings.defaults
    settings.prompts = [chosen]
    settings.selectedPromptID = chosen.id
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: settings,
        config: regressionConfig(),
        rewriteRunner: { _, _ in "tidied" })
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(inserter.inserts == ["tidied "])
    #expect(await loop.isPressActive == false)
    #expect(await loop.currentState == .idle)
}

@Test func serviceRestartClearsTheActiveTake() async {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let loop = DictationOrchestrator(
        audio: StillAudio(),
        makeService: { _ in TranscriptionService(client: HangingCancelClient(cancel: gate), shutdownTimeout: 0.05) },
        config: regressionConfig(), shutdownTimeout: 0.05)
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(await loop.snapshot.requiresRestart)
    #expect(await loop.isPressActive == false)
    #expect(await loop.currentState == .idle)
    #expect(!gate.isReleased)
}

@Test func stopCaptureTimeoutClearsTheActiveTake() async {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let loop = DictationOrchestrator(
        audio: StillAudio(),
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: regressionConfig(), pressEnder: { await gate.wait() }, shutdownTimeout: 0.05)
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(await loop.snapshot.requiresRestart)
    #expect(await loop.isPressActive == false)
    #expect(await loop.currentState == .idle)
    #expect(!gate.isReleased)
}

@Test func emptyFinalSurfacesTheNoSpeechTerminalState() async throws {
    let service = TranscriptionService(client: MockTranscriptionClient(script: .emptyFinal))
    let stream = await service.states()
    let collected = Task {
        var seen: [PushToTalkState] = []
        for await state in stream {
            seen.append(state)
            if seen.count >= 4 { break }
        }
        return seen
    }
    try await service.start(config: regressionConfig())
    await service.finish()
    guard let seen = try? await AsyncDeadline.run(seconds: 5, operation: { await collected.value }) else {
        Issue.record("the blank terminal never reached observers")
        return
    }
    // The blank terminal explains "No speech was recognized" in the menu.
    #expect(seen.contains(.final("")))
    #expect(seen.last == .idle)
    #expect(await service.lastFinal == nil)
}

@Test func wedgedInsertionLatchesAVisibleRestartInsteadOfSilentlyWedging() async {
    let inserter = BlockingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: regressionConfig(),
        insertionTimeout: 0.1)
    await loop.pressBegan()
    // An inserter parked forever used to keep this from ever returning, with
    // the take never cleared and no error surfaced.
    await loop.pressEnded()
    #expect(inserter.started.value)
    let snapshot = await loop.snapshot
    #expect(snapshot.requiresRestart)
    #expect(snapshot.lastError == DictationOrchestrator.insertionStalledMessage)
    let activeAfterTimeout = await loop.isPressActive
    #expect(!activeAfterTimeout)
    // Later presses are refused visibly (restart latched), not silently.
    await loop.pressBegan()
    let activeAfterPress = await loop.isPressActive
    #expect(!activeAfterPress)
    inserter.released.set()
}

/// Gate-released inserter that outlives the generic shutdown deadline.
final class SlowInserter: TextInserting, @unchecked Sendable {
    let started = LockedFlag()
    let released = LockedFlag()
    let completed = LockedFlag()
    private let lock = NSLock()
    private var stored: [String] = []
    func insert(_ text: String) {
        started.set()
        while !released.value {
            Thread.sleep(forTimeInterval: 0.002)
        }
        lock.lock()
        stored.append(text)
        lock.unlock()
        completed.set()
    }
    var inserts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Test func stopDuringASlowButHealthyInsertionWaitsForItsOwnBudget() async throws {
    let inserter = SlowInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: regressionConfig(),
        shutdownTimeout: 0.05,
        insertionTimeout: 5)
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    let deadline = Date().addingTimeInterval(10)
    while !inserter.started.value, Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(inserter.started.value)
    // Stop joins this slow insert under its own budget, without latching restart.
    let stopping = Task { await loop.stop() }
    try? await Task.sleep(nanoseconds: 100_000_000)
    inserter.released.set()
    let shutdown = await stopping.value
    #expect(shutdown == .clean)
    #expect(await loop.requiresRestart == false)
    #expect(inserter.completed.value)
    _ = await ending.value
    #expect(inserter.inserts == ["hello world "])
}

@Test func pumpDeadlineAfterAPublishedFinalStillInsertsIt() async throws {
    let client = CancelUnparksSendClient()
    let inserter = RecordingInserter()
    // The pump parks in its first write while the reader still delivers:
    // the server final publishes before the (short, injectable) pump
    // deadline fires.
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: regressionConfig(),
        pumpTimeout: 0.2)
    try #require(await loop.pressBegan())
    try await AsyncDeadline.run(seconds: 5) { await client.waitUntilParked() }
    client.channel.continuation.yield(.final("spoken words"))
    try await AsyncDeadline.run(seconds: 5) {
        while await loop.snapshot.lastTerminal != .final("spoken words") {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    await loop.pressEnded()
    #expect(inserter.inserts == ["spoken words "])
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(!snapshot.requiresRestart)
    #expect(snapshot.lastTerminal == .final("spoken words"))
    // The service was closed, not leaked: cancelling aborts the parked write
    // (the URLSession contract) and shutdown joins it inside its deadline.
    #expect(client.cancels.get() == 1)
}

/// A transport whose parked write is aborted by `cancel()`, like a real
/// socket task, so shutdown can join it promptly.
private final class CancelUnparksSendClient: TranscriptionClient, Sendable {
    let cancels = TestValue(0)
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    private let sendGate = ManualGate()

    func waitUntilParked() async { await sendGate.waitUntilEntered() }
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws { await sendGate.wait() }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {}
    func cancel() async {
        cancels.update { $0 += 1 }
        sendGate.release()
        channel.continuation.finish(throwing: CancellationError())
    }
}

/// A transport wedged in both its write and its cancel: the transcript must
/// still be inserted, and the cleanup that cannot join must latch the same
/// visible restart the normal stop path would.
final class WedgedTransportClient: TranscriptionClient, Sendable {
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    private let sendGate = ManualGate()
    private let cancelGate = ManualGate()

    func waitUntilParked() async { await sendGate.waitUntilEntered() }
    func releaseGates() {
        sendGate.release()
        cancelGate.release()
    }
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws { await sendGate.wait() }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {}
    func cancel() async { await cancelGate.wait() }
}

@Test func pumpDeadlineWithAWedgedTransportStillInsertsThenLatchesRestart() async throws {
    let client = WedgedTransportClient()
    defer { client.releaseGates() }
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client, shutdownTimeout: 0.1) },
        config: regressionConfig(),
        pumpTimeout: 0.2)
    try #require(await loop.pressBegan())
    try await AsyncDeadline.run(seconds: 5) { await client.waitUntilParked() }
    client.channel.continuation.yield(.final("spoken words"))
    try await AsyncDeadline.run(seconds: 5) {
        while await loop.snapshot.lastTerminal != .final("spoken words") {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    await loop.pressEnded()
    // The result is preserved; the wedged cleanup quarantines further dictation.
    #expect(inserter.inserts == ["spoken words "])
    let snapshot = await loop.snapshot
    #expect(snapshot.requiresRestart)
    #expect(snapshot.lastError == TranscriptionService.restartMessage)
    #expect(snapshot.lastTerminal == .final("spoken words"))
}

@Test func pumpDeadlineWithAFinalLandingInTheErrorWindowStillInsertsIt() async throws {
    let client = CancelUnparksSendClient()
    let inserter = RecordingInserter()
    // The pump parks; the deadline fires before any final exists, and the
    // final arrives inside the failed-send settle window — it must still
    // be the take's result.
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: regressionConfig(),
        pumpTimeout: 0.15)
    try #require(await loop.pressBegan())
    try await AsyncDeadline.run(seconds: 5) { await client.waitUntilParked() }
    let ending = Task { await loop.pressEnded() }
    // Past the deadline (error path entered) but inside the settle bound.
    try await Task.sleep(nanoseconds: 220_000_000)
    client.channel.continuation.yield(.final("late words"))
    await ending.value
    #expect(inserter.inserts == ["late words "])
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(!snapshot.requiresRestart)
    #expect(snapshot.lastTerminal == .final("late words"))
}

@Test func aPressDuringThePostDeadlineServiceCloseWaitsForTheBarrier() async throws {
    let client = WedgedTransportClient()
    defer { client.releaseGates() }
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client, shutdownTimeout: 5) },
        config: regressionConfig(),
        pumpTimeout: 0.15)
    try #require(await loop.pressBegan())
    try await AsyncDeadline.run(seconds: 5) { await client.waitUntilParked() }
    client.channel.continuation.yield(.final("spoken words"))
    try await AsyncDeadline.run(seconds: 5) {
        while await loop.snapshot.lastTerminal != .final("spoken words") {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    let ending = Task { await loop.pressEnded() }
    try await AsyncDeadline.run(seconds: 5) {
        while inserter.inserts.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    // Busy guidance must not replace the just-inserted final.
    try await Task.sleep(nanoseconds: 50_000_000)
    let beforeBusy = await loop.snapshot
    await loop.reportBusyPress()
    let busy = await loop.snapshot
    #expect(busy.lastError == nil)
    #expect(busy.busyPressRevision == beforeBusy.busyPressRevision + 1)
    #expect(busy.lastTerminal == beforeBusy.lastTerminal)
    #expect(busy.terminalRevision == beforeBusy.terminalRevision)
    #expect(await loop.pressBegan() == false)
    client.releaseGates()
    try await AsyncDeadline.run(seconds: 10) { await ending.value }
    #expect(inserter.inserts == ["spoken words "])
    #expect(await loop.requiresRestart == false)
}

@Test func aConcurrentStopDoesNotOverwriteTheInsertionStallDiagnosis() async throws {
    let inserter = BlockingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: regressionConfig(),
        insertionTimeout: 0.1)
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    let deadline = Date().addingTimeInterval(10)
    while !inserter.started.value, Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(inserter.started.value)
    let shutdown = await loop.stop()
    #expect(shutdown == .timedOut)
    // The first-latched insertion diagnosis wins over the generic timeout.
    let snapshot = await loop.snapshot
    #expect(snapshot.requiresRestart)
    #expect(snapshot.lastError == DictationOrchestrator.insertionStalledMessage)
    _ = await ending.value
    inserter.released.set()
}
