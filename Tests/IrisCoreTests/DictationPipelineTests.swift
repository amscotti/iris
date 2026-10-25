import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

// MARK: - Doubles

/// Scripted audio source: replays fixed frames, then ends.
final class LoopAudio: AudioCapturing, @unchecked Sendable {
    private let framesToReplay: [PCMFrame]

    init(frames: [PCMFrame] = []) {
        self.framesToReplay = frames
    }

    func frames() -> AsyncStream<PCMFrame> {
        let replay = framesToReplay
        return AsyncStream { continuation in
            for frame in replay { continuation.yield(frame) }
            continuation.finish()
        }
    }

}

/// Scripted hotkey source: replays fixed edges, then ends.
final class LoopHotkey: HotkeyMonitoring, @unchecked Sendable {
    private let edges: [HotkeyEvent]

    init(events: [HotkeyEvent]) {
        self.edges = events
    }

    func events() -> AsyncStream<HotkeyEvent> {
        let edges = edges
        return AsyncStream { continuation in
            for edge in edges { continuation.yield(edge) }
            continuation.finish()
        }
    }
}

/// Recording inserter: captures every insert for assertions.
final class RecordingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func insert(_ text: String) {
        lock.lock()
        stored.append(text)
        lock.unlock()
    }

    var inserts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func loopConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

func waitForLoop(_ description: String = "", until condition: @escaping @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting: \(description)")
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private struct LoopFixture: Sendable {
    var loop: DictationOrchestrator
    var client: MockTranscriptionClient
    var inserter: RecordingInserter
}

private func makeLoop(
    client: MockTranscriptionClient? = nil,
    frames: [PCMFrame] = [PCMFrame(samples: [1000, -1000, 1000, -1000])],
    settings: AppSettings = .defaults
) -> LoopFixture {
    let resolved = client ?? MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: frames),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: resolved) },
        settings: settings,
        config: loopConfig())
    return LoopFixture(loop: loop, client: resolved, inserter: inserter)
}

// MARK: - Preparation policy

@Test func blankTranscriptsPrepareToNothing() {
    #expect(DictationTextProcessor.prepare("") == nil)
    #expect(DictationTextProcessor.prepare("   ") == nil)
    #expect(DictationTextProcessor.prepare("\n\t ") == nil)
}

@Test func trailingSeparatorsFollowToggles() {
    #expect(DictationTextProcessor.prepare("hello") == "hello ")
    #expect(DictationTextProcessor.prepare("hello", trailingSpace: false, trailingNewline: false) == "hello")
    #expect(DictationTextProcessor.prepare("hello", trailingSpace: false, trailingNewline: true) == "hello\n")
    #expect(DictationTextProcessor.prepare("hello ", trailingSpace: true) == "hello ")
    #expect(DictationTextProcessor.prepare("hello\n", trailingSpace: true) == "hello\n")
}

@Test func longTranscriptsChunkWithinLimits() {
    let text = String(repeating: "a", count: 5_000)
    let chunks = DictationTextProcessor.chunk(text)
    #expect(chunks.count == 250)  // 5000 UTF-16 units at the 20-unit ceiling
    #expect(chunks.allSatisfy { $0.utf16.count <= DictationTextProcessor.maxChunkUTF16 })
    #expect(chunks.joined() == text)
}

@Test func chunkingKeepsMultiUnitCharactersIntact() {
    let text = String(repeating: "🎉", count: 1_001)
    let chunks = DictationTextProcessor.chunk(text)
    // Each chunk holds whole graphemes within the UTF-16 budget: 10 emoji
    // (20 units) per chunk, so 1001 emoji split into 101 chunks.
    #expect(chunks.count == 101)
    #expect(chunks.allSatisfy { $0.utf16.count <= DictationTextProcessor.maxChunkUTF16 })
    #expect(chunks.joined() == text)
}

// MARK: - Full loop

@Test func pressStreamsAudioThenInsertsFinalOnce() async {
    let fixture = makeLoop()
    await fixture.loop.pressBegan()
    await waitForLoop("audio reaches the client") { fixture.client.receivedFrameCount >= 1 }
    await fixture.loop.pressEnded()
    #expect(fixture.inserter.inserts == ["hello world "])
    #expect(await fixture.loop.isPressActive == false)
}

@Test func emptyFinalInsertsNothing() async {
    let client = MockTranscriptionClient(script: .emptyFinal)
    let fixture = makeLoop(client: client)
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    #expect(fixture.inserter.inserts.isEmpty)
}

@Test func overlappingPressBeganIsIgnored() async {
    let fixture = makeLoop()
    await fixture.loop.pressBegan()
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    #expect(fixture.inserter.inserts == ["hello world "])
}

@Test func pressBeganDuringFinalizeIsIgnored() async {
    let enderStarted = LockedFlag()
    let allowEnder = LockedFlag()
    let inserter = RecordingInserter()
    let client = MockTranscriptionClient()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        settings: .defaults,
        config: loopConfig(),
        pressEnder: {
            enderStarted.set()
            while !allowEnder.value {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        })
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    let deadline = Date().addingTimeInterval(10)
    while !enderStarted.value, Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    #expect(enderStarted.value)
    await loop.pressBegan()
    allowEnder.set()
    await ending.value
    #expect(inserter.inserts == ["hello world "])
    #expect(await loop.isPressActive == false)
}

@Test func strayPressEndedIsANoOp() async {
    let fixture = makeLoop()
    await fixture.loop.pressEnded()
    #expect(fixture.inserter.inserts.isEmpty)
}

@Test func failingPressInsertsNothingAndNextPressRecovers() async {
    let client = MockTranscriptionClient()
    client.finishError = TranscriptionError(kind: .network, message: "dropped")
    let fixture = makeLoop(client: client)
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    #expect(fixture.inserter.inserts.isEmpty)

    client.finishError = nil
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    #expect(fixture.inserter.inserts == ["hello world "])
}

@Test func holdEdgesDriveOneUtterance() async throws {
    let fixture = makeLoop()
    try await runRecordingHotkeyScript([.pressed, .released], on: fixture.loop)
    #expect(fixture.inserter.inserts == ["hello world "])
}

@Test func toggleEdgesDriveOneUtterance() async throws {
    var settings = AppSettings.defaults
    settings.hotkey = HotkeyConfiguration(keyCode: 61, modifiers: 0, mode: .toggle)
    let fixture = makeLoop(settings: settings)
    try await runRecordingHotkeyScript([.pressed, .released, .pressed, .released], on: fixture.loop)
    #expect(fixture.inserter.inserts == ["hello world "])
}

@Test func danglingPressFinishesWhenTheStreamEnds() async throws {
    let fixture = makeLoop()
    try await runRecordingHotkeyScript([.pressed], on: fixture.loop)
    #expect(fixture.inserter.inserts == ["hello world "])
}

@Test func vetoedPressNeverStarts() async {
    let inserter = RecordingInserter()
    let client = MockTranscriptionClient()
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        settings: .defaults,
        config: loopConfig(),
        gate: { "Microphone access is off." })
    let states = await loop.states()
    await loop.pressBegan()
    #expect(await loop.isPressActive == false)
    #expect(client.startCallCount == 0)
    #expect(inserter.inserts.isEmpty)
    var sawError = false
    for await state in states {
        if state == .error("Microphone access is off.") { sawError = true }
        if state == .idle, sawError { break }
    }
    #expect(sawError)
}

@Test func captureHooksBracketAPress() async {
    let started = LockedFlag()
    let stopped = LockedFlag()
    let inserter = RecordingInserter()
    let client = MockTranscriptionClient()
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        settings: .defaults,
        config: loopConfig(),
        pressStarter: {
            started.set()
            return nil
        },
        pressEnder: { stopped.set() })
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(started.value)
    #expect(stopped.value)
    #expect(inserter.inserts == ["hello world "])
}

@Test func refusedCaptureAbortsBeforeSessionStart() async {
    let inserter = RecordingInserter()
    let client = MockTranscriptionClient()
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        settings: .defaults,
        config: loopConfig(),
        pressStarter: { "Microphone unavailable." })
    await loop.pressBegan()
    #expect(await loop.isPressActive == false)
    #expect(client.startCallCount == 0)
    #expect(inserter.inserts.isEmpty)
}

/// Simple Sendable flag for hook assertions.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Blocking inserter: parks its worker thread until released, so a stop can
/// race an in-flight insertion (insertion runs on a GCD worker by design).
final class BlockingInserter: TextInserting, @unchecked Sendable {
    let started = LockedFlag()
    let released = LockedFlag()
    let completed = LockedFlag()
    func insert(_ text: String) {
        started.set()
        while !released.value {
            Thread.sleep(forTimeInterval: 0.002)
        }
        completed.set()
    }
}

@Test func stopJoinsAnInFlightInsertionBeforeReportingClean() async {
    let inserter = BlockingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: loopConfig())
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    await waitForLoop("insertion starts") { inserter.started.value }

    let stopFinished = LockedFlag()
    let stopping = Task { () -> SessionShutdown in
        let result = await loop.stop()
        stopFinished.set()
        return result
    }
    // stop() must join the parked insertion inside its shutdown deadline
    // instead of reporting clean while keystrokes are still pending.
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(!stopFinished.value)
    inserter.released.set()
    let shutdown = await stopping.value
    _ = await ending.value
    #expect(shutdown == .clean)
    #expect(inserter.completed.value)
}

@Test func togglePressDuringFinalizeDoesNotClaimEngagement() async throws {
    var toggleSettings = AppSettings.defaults
    toggleSettings.hotkey = HotkeyConfiguration(keyCode: 61, modifiers: 0, mode: .toggle)
    let enderStarted = LockedFlag()
    let allowEnder = LockedFlag()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: toggleSettings,
        config: loopConfig(),
        pressEnder: {
            enderStarted.set()
            while !allowEnder.value {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        })
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    await waitForLoop("finalize enters the ender") { enderStarted.value }
    // A toggle press that lands while the take is finalizing must not claim
    // engagement: the old behavior reported `take != nil` and desynced.
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
        allowEnder.set()
    }
    let states = await loop.states()
    feed.emit(.pressed)
    feed.emit(.released)
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error(DictationOrchestrator.busyMessage) { return }
    }
    allowEnder.set()
    _ = await ending.value
    feed.emit(.pressed)
    try await waitForRecording(loop)
    feed.emit(.released)
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(inserter.inserts == ["hello world ", "hello world "])
}
