import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func chordConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

@Test func typingChordDiscardsThePressSilently() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) }, config: chordConfig())
    // Without the cancel, the loop's end-of-stream cleanup would finalize
    // and insert this take.
    try await runRecordingHotkeyScript([.pressed, .cancelled], on: loop)
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(snapshot.lastTerminal == nil)
    let active = await loop.isPressActive
    #expect(!active)
}

@Test func typingChordCancelsAPressWhoseSessionIsStillStarting() async {
    let gateFinished = LockedFlag()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: RecordingInserter(),
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) }, config: chordConfig(),
        gate: {
            // Stands in for a slow startup; cancellation must cut it short.
            do {
                try await Task.sleep(for: .seconds(30))
                gateFinished.set()
            } catch {}
            return nil
        })
    await loop.run(hotkey: LoopHotkey(events: [.pressed, .cancelled]))
    #expect(!gateFinished.value)
    let active = await loop.isPressActive
    #expect(!active)
}

@Test func toggleModePressAfterAChordStartsAFreshTake() async throws {
    var settings = AppSettings.defaults
    settings.hotkey = HotkeyConfiguration(keyCode: 61, modifiers: 0, mode: .toggle)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) }, settings: settings,
        config: chordConfig())
    try await runRecordingHotkeyScript([.pressed, .cancelled], on: loop)
    try await runRecordingHotkeyScript([.pressed], on: loop)
    // The chorded take is discarded; the next press starts (and, at stream
    // end, finishes) a new one instead of only resyncing toggle state.
    #expect(inserter.inserts.count == 1)
}

@Test func toggleModeChordFromIdleDiscardsWithoutInserting() async throws {
    var settings = AppSettings.defaults
    settings.hotkey = HotkeyConfiguration(keyCode: 61, modifiers: 0, mode: .toggle)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) }, settings: settings,
        config: chordConfig())
    // A chord that begins in toggle mode must discard the just-started take.
    // If the cancel were ignored, the end-of-stream tail would finalize it
    // and insert the mock transcript.
    try await runRecordingHotkeyScript([.pressed, .cancelled], on: loop)
    #expect(inserter.inserts.isEmpty)
    let active = await loop.isPressActive
    #expect(!active)
}

@Test func pressWhileBusySurfacesNoticeInsteadOfDroppingSilently() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: chordConfig())
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    let states = await loop.states()
    feed.emit(.pressed)
    try await waitForRecording(loop)
    // The middle press lands while the first take is still active. It must
    // not start a second take, and it must say so instead of vanishing.
    feed.emit(.pressed)
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error(DictationOrchestrator.busyMessage) { return }
    }
    feed.emit(.released)
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(inserter.inserts.count == 1)
    // The notice must not outlive the take it refused: the completed final
    // is the retained terminal, with no lingering busy error.
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(snapshot.lastTerminal == .final("hello world"))
}

@Test func busyPressBeforeTheFinalDoesNotOutliveTheCompletedTake() async throws {
    let enderStarted = LockedFlag()
    let allowEnder = LockedFlag()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: chordConfig(),
        pressEnder: {
            enderStarted.set()
            while !allowEnder.value {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        })
    await loop.pressBegan()
    let ending = Task { await loop.pressEnded() }
    let entered = Date().addingTimeInterval(10)
    while !enderStarted.value, Date() < entered {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    #expect(enderStarted.value)
    // A press lands during finalization, before the final is published.
    await loop.reportBusyPress()
    let busy = await loop.snapshot
    #expect(busy.lastError == DictationOrchestrator.busyMessage)
    allowEnder.set()
    await ending.value
    #expect(inserter.inserts == ["hello world "])
    // The busy notice must not stick over the take's own successful final.
    let final = await loop.snapshot
    #expect(final.lastError == nil)
    #expect(final.lastTerminal == .final("hello world"))
}

@Test func togglePressAfterAMidTakeErrorStartsFresh() async throws {
    var settings = AppSettings.defaults
    settings.hotkey = HotkeyConfiguration(keyCode: 61, modifiers: 0, mode: .toggle)
    let first = ControlledClient()
    let creations = TestValue(0)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in
            let index = creations.update {
                $0 += 1
                return $0
            }
            return TranscriptionService(client: index == 1 ? first : MockTranscriptionClient())
        }, settings: settings,
        config: chordConfig())
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await waitForRecording(loop)
    feed.emit(.released)
    let states = await loop.states()
    first.channel.continuation.yield(.error(TranscriptionError(kind: .network, message: "boom")))
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error("boom") { return }
    }
    let inactive = await loop.isPressActive
    #expect(!inactive)
    #expect(await loop.waitForCleanup() == .clean)
    #expect((await loop.snapshot).lastError == "boom")
    // The loop's old toggle id must not burn the next press on a dead take.
    feed.emit(.pressed)
    try await waitForRecording(loop)
    feed.emit(.released)
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(creations.get() == 2)
    #expect(inserter.inserts == ["hello world "])
}

@Test func quickTapWithEmptyResultStaysSilent() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient(script: .emptyFinal)) },
        config: chordConfig())
    // An accidental tap that yields no transcript must not report "no
    // speech": nothing is inserted and no terminal is recorded.
    try await runRecordingHotkeyScript([.pressed, .released], on: loop)
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(snapshot.lastTerminal == nil)
    let active = await loop.isPressActive
    #expect(!active)
}

@Test func quickTapWithServerCloseStaysSilent() async throws {
    let transport = TestTransport(
        serverFrames: [Data(#"{"sessionId":"s-1"}"#.utf8)],
        closeError: TranscriptionError.closed("The speech service disconnected before finishing. Try again."))
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in
            TranscriptionService(
                client: MetaVoiceTranscribeClient(transport: transport),
                completion: MetaProvider().completionPolicy(
                    for: ProviderConfiguration(
                        provider: .meta,
                        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "sessionId": "s-1"])))
        },
        config: ProviderConfiguration(
            provider: .meta,
            values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "sessionId": "s-1"]))
    try await runRecordingHotkeyScript([.pressed, .released], on: loop)
    // The server closed without any completion event right after recording
    // started: the signature of an accidental tap, not a failure to report.
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(snapshot.lastTerminal == nil)
    // The provider session is still closed, not left dangling.
    #expect(transport.didClose)
}

@Test func quickTapWithRecordedTurnTextSurfacesTheServerClose() async throws {
    let client = ControlledClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client, completion: .turnComplete) },
        config: chordConfig())
    try #require(await loop.pressBegan())
    // Words riding only on the endpointing boundary: no partial or final
    // ever arrives, but the session recorded a real turn.
    client.channel.continuation.yield(.speechComplete(turnId: "1", transcript: "hello world"))
    client.channel.continuation.finish(
        throwing: TranscriptionError(
            kind: .serverClosed, message: "The speech service disconnected before finishing. Try again."))
    let message = "The speech service disconnected before finishing. Try again."
    let states = await loop.states()
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error(message) { return }
    }
    await loop.pressEnded()
    // Real dictated words were recorded: this is not an accidental tap, so
    // the failure must surface instead of being silently dropped.
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == message)
    #expect(snapshot.lastTerminal == .error(message))
}

@Test func longerTakeWithEmptyResultStillReports() async {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient(script: .emptyFinal)) },
        config: chordConfig(), silentTakeSeconds: 0.05)
    // A take held well past the accidental-tap window keeps the "no speech"
    // terminal even when nothing was transcribed.
    await loop.pressBegan()
    try? await Task.sleep(nanoseconds: 150_000_000)
    await loop.pressEnded()
    #expect(inserter.inserts.isEmpty)
    #expect((await loop.snapshot).lastTerminal == .final(""))
}

/// A hotkey feed that stays open until the test finishes it, so end-of-stream
/// cleanup cannot finalize a take mid-assertion.
private final class ChordFeed: HotkeyMonitoring, @unchecked Sendable {
    private let stream = AsyncStream.makeStream(of: HotkeyEvent.self)
    func events() -> AsyncStream<HotkeyEvent> { stream.stream }
    func emit(_ event: HotkeyEvent) { stream.continuation.yield(event) }
    func finish() { stream.continuation.finish() }
}

@Test func toggleChordWhileAnEstablishedRecordingRunsKeepsIt() async {
    var settings = AppSettings.defaults
    settings.hotkey = HotkeyConfiguration(keyCode: 61, modifiers: 0, mode: .toggle)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) }, settings: settings,
        config: chordConfig(), silentTakeSeconds: 0.05)
    let feed = ChordFeed()
    let running = Task { await loop.run(hotkey: feed) }
    feed.emit(.pressed)
    let deadline = Date().addingTimeInterval(10)
    while !(await loop.isPressActive), Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    // Let the recording age past the accidental-tap window.
    try? await Task.sleep(nanoseconds: 150_000_000)
    // A chord pressed while an established toggle recording runs is typing,
    // not a stop: the recording must survive.
    feed.emit(.cancelled)
    try? await Task.sleep(nanoseconds: 100_000_000)
    let active = await loop.isPressActive
    #expect(active)
    // The next real press stops and inserts the take.
    feed.emit(.pressed)
    feed.emit(.released)
    let insertDeadline = Date().addingTimeInterval(10)
    while inserter.inserts.isEmpty, Date() < insertDeadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(inserter.inserts.count == 1)
    feed.finish()
    _ = await running.value
}

@Test func aShortTakeWithTranscriptStillReports() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]), inserter: inserter,
        makeService: { _ in
            TranscriptionService(client: MockTranscriptionClient(script: .init(partials: ["hi"], final: "")))
        },
        config: chordConfig())
    // Once any transcript text arrived, the accidental-tap rule is off: the
    // blank final must still surface as the no-speech terminal.
    try await runRecordingHotkeyScript([.pressed, .released], on: loop)
    #expect((await loop.snapshot).lastTerminal == .final(""))
}

@Test func busyNoticeDoesNotConsumeTheTakesOneRealError() async {
    let client = ScriptedClient(
        events: [], terminalError: TranscriptionError(kind: .network, message: "provider exploded"))
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: RecordingInserter(),
        makeService: { _ in TranscriptionService(client: client) },
        config: chordConfig())
    await loop.pressBegan()
    await loop.reportBusyPress()
    #expect((await loop.snapshot).lastError?.contains("Finishing") == true)
    // The real failure must still be reported: the busy notice uses its own
    // latch, not the take's single error-report slot.
    await loop.pressEnded()
    #expect((await loop.snapshot).lastError == "provider exploded")
}
