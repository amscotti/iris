import Foundation
import IrisProviders
import Testing

@testable import IrisCore

@Test func retiredTakeCannotStartARewriteOrChangeIdleState() async throws {
    let calls = TestValue(0)
    let prompt = PromptDefinition(template: "Rewrite")
    let settings = AppSettings(prompts: [prompt], selectedPromptID: prompt.id)
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: settings, config: ProviderConfiguration(provider: .mock),
        rewriteRunner: { text, _ in
            calls.update { $0 += 1 }
            return text
        })
    try #require(await loop.pressBegan())
    let retired = try #require(await loop.currentTake)
    #expect(await loop.stop() == .clean)
    #expect(await loop.enhance("retired text", take: retired) == "retired text")
    #expect(calls.get() == 0)
    #expect((await loop.snapshot).state == .idle)
    #expect(await loop.requiresRestart == false)
}

@Test func localConfigurationUpdatesAreUsedByTheNextTake() async throws {
    let seen = TestValue<[ProviderConfiguration]>([])
    let initial = ProviderConfiguration(provider: .mock, values: ["route": "old"])
    let updated = ProviderConfiguration(provider: .mock, values: ["route": "new"])
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        makeService: { config in
            seen.update { $0.append(config) }
            return TranscriptionService(client: MockTranscriptionClient())
        }, config: initial)
    #expect(await loop.update(settings: .defaults, config: updated))
    try #require(await loop.pressBegan())
    await loop.pressEnded()
    #expect(seen.get() == [updated])
}

@Test func suppliedConfigurationHasNoUnusedLocalShadow() async throws {
    let initial = ProviderConfiguration(provider: .mock, values: ["route": "source"])
    let source = TestValue(DictationOrchestrator.Configuration(settings: .defaults, config: initial))
    let seen = TestValue<[ProviderConfiguration]>([])
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        makeService: { config in
            seen.update { $0.append(config) }
            return TranscriptionService(client: MockTranscriptionClient())
        }, config: initial, configurationSource: { source.get() })
    #expect(await loop.update(settings: .defaults, config: ProviderConfiguration(provider: .mock)) == false)
    let updated = ProviderConfiguration(provider: .mock, values: ["route": "source update"])
    source.update { $0.config = updated }
    try #require(await loop.pressBegan())
    await loop.pressEnded()
    #expect(seen.get() == [updated])
}

@Test func hotkeyPressDuringSilentCleanupReportsBusyWithoutReplaying() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = HangingCancelClient(cancel: gate)
    let creations = TestValue(0)
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        makeService: { _ in
            creations.update { $0 += 1 }
            return TranscriptionService(client: client)
        }, config: ProviderConfiguration(provider: .mock))
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await waitForRecording(loop)
    feed.emit(.cancelled)
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    let states = await loop.states()
    feed.emit(.pressed)
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .error(DictationOrchestrator.busyMessage) { return }
    }
    #expect(creations.get() == 1)
    #expect((await loop.snapshot).lastError == DictationOrchestrator.busyMessage)
    feed.emit(.released)
    gate.release()
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(creations.get() == 1)
}

private final class RewriteFallbackInserter: TextInserting, Sendable {
    let entered = AsyncStream.makeStream(of: Void.self)
    let release = DispatchSemaphore(value: 0)
    func insert(_ text: String) {
        entered.continuation.yield(())
        _ = release.wait(timeout: .now() + 10)
    }
}

@Test func busyPressDuringRewriteFallbackInsertionKeepsTheRewriteFailure() async throws {
    let inserter = RewriteFallbackInserter()
    defer { inserter.release.signal() }
    let prompt = PromptDefinition(template: "Rewrite")
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: AppSettings(prompts: [prompt], selectedPromptID: prompt.id),
        config: ProviderConfiguration(provider: .mock), rewriteRunner: { _, _ in nil })
    try #require(await loop.pressBegan())
    let ending = Task { await loop.pressEnded() }
    defer { ending.cancel() }
    try await AsyncDeadline.run(seconds: 5) {
        var input = inserter.entered.stream.makeAsyncIterator()
        _ = await input.next()
    }
    let failure = await loop.snapshot
    #expect(failure.lastError == "Rewrite failed. Inserted the original text.")
    await loop.reportBusyPress()
    let busy = await loop.snapshot
    #expect(busy.lastError == failure.lastError)
    #expect(busy.lastTerminal == failure.lastTerminal)
    #expect(busy.terminalRevision == failure.terminalRevision)
    inserter.release.signal()
    try await AsyncDeadline.run(seconds: 5) { await ending.value }
}

@Test func captureFailureEndsTheRecordingWithoutInserting() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock))
    try #require(await loop.pressBegan())
    let message = "The microphone stopped before dictation finished. Try again."
    await loop.failCapture(message)
    try await AsyncDeadline.run(seconds: 5) {
        while await loop.isPressActive {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    #expect(inserter.inserts.isEmpty)
    #expect((await loop.snapshot).lastError == message)
}

@Test func delayedCaptureFailureCannotEndANewerTake() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock))

    try #require(await loop.pressBegan())
    let firstID = try #require(await loop.currentTake?.id)
    await loop.failCapture("First capture failed.", expectedTakeID: firstID)
    #expect(await loop.waitForCleanup() == .clean)
    #expect((await loop.snapshot).lastError == "First capture failed.")

    try #require(await loop.pressBegan())
    let secondID = try #require(await loop.currentTake?.id)
    #expect(secondID != firstID)
    await loop.failCapture("Delayed first capture failure.", expectedTakeID: firstID)
    let surviving = await loop.snapshot
    #expect(surviving.activeTakeID == secondID)
    #expect(surviving.lastError == nil)

    await loop.failCapture("Second capture failed.", expectedTakeID: secondID)
    #expect(await loop.waitForCleanup() == .clean)
    let failed = await loop.snapshot
    #expect(failed.activeTakeID == nil)
    #expect(failed.lastError == "Second capture failed.")
    #expect(!failed.requiresRestart)
    #expect(inserter.inserts.isEmpty)
}

/// Client whose session open parks cooperatively, standing in for a slow
/// provider handshake during the orchestrator's `.starting` window.
private final class SlowStartClient: TranscriptionClient, Sendable {
    let started = LockedFlag()
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    func start(config: ProviderConfiguration) async throws {
        started.set()
        try await Task.sleep(for: .seconds(30))
    }
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws { channel.continuation.finish() }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test func captureFailureDuringStartupBeforeTheSessionEndsTheTake() async throws {
    let gateEntered = LockedFlag()
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock),
        gate: {
            gateEntered.set()
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            return nil
        })
    let starting = Task { await loop.pressBegan() }
    try await AsyncDeadline.run(seconds: 5) {
        while !gateEntered.value {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    // The microphone dies while startup is still gated: the take must end
    // with the capture notice instead of succeeding as blank audio.
    let message = "The microphone stopped before dictation finished. Try again."
    await loop.failCapture(message)
    #expect(await starting.value == false)
    #expect(client.startCallCount == 0)
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == message)
    #expect(!snapshot.requiresRestart)
    #expect(await loop.isPressActive == false)
}

@Test func captureFailureDuringASlowSessionStartEndsTheTake() async throws {
    let client = SlowStartClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock))
    let starting = Task { await loop.pressBegan() }
    try await AsyncDeadline.run(seconds: 5) {
        while !client.started.value {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    let message = "The microphone stopped before dictation finished. Try again."
    await loop.failCapture(message)
    #expect(await starting.value == false)
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == message)
    #expect(!snapshot.requiresRestart)
    #expect(await loop.waitForCleanup() == .clean)
}

/// Client whose finish parks cooperatively, holding the take in
/// `.finalizing` with no terminal outcome yet.
private final class SlowFinishClient: TranscriptionClient, Sendable {
    let finishing = LockedFlag()
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    func start(config: ProviderConfiguration) async throws {
        channel.continuation.yield(.partial("hello"))
    }
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        finishing.set()
        try await Task.sleep(for: .seconds(30))
        channel.continuation.finish()
    }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test func captureFailureDuringFinalizationReportsInsteadOfInserting() async throws {
    let client = SlowFinishClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: ProviderConfiguration(provider: .mock))
    try #require(await loop.pressBegan())
    let ending = Task { await loop.pressEnded() }
    try await AsyncDeadline.run(seconds: 5) {
        while !client.finishing.value {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    let message = "The microphone stopped before dictation finished. Try again."
    await loop.failCapture(message)
    await ending.value
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == message)
    #expect(!snapshot.requiresRestart)
    #expect(await loop.isPressActive == false)
}

@Test func busyPressAfterAPublishedFinalKeepsThatFinal() async throws {
    let inserter = RewriteFallbackInserter()
    defer { inserter.release.signal() }
    let cancelled = LockedFlag()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock),
        onCancelledTake: { _, _ in cancelled.set() })
    try #require(await loop.pressBegan())
    let ending = Task { await loop.pressEnded() }
    defer { ending.cancel() }
    try await AsyncDeadline.run(seconds: 5) {
        var input = inserter.entered.stream.makeAsyncIterator()
        _ = await input.next()
    }
    let published = await loop.snapshot
    #expect(published.lastTerminal == .final("hello world"))
    await loop.reportBusyPress()
    let busy = await loop.snapshot
    #expect(busy.lastError != DictationOrchestrator.busyMessage)
    #expect(busy.lastTerminal == .final("hello world"))
    #expect(busy.terminalRevision == published.terminalRevision)
    let stopping = Task { await loop.stop() }
    inserter.release.signal()
    #expect(await stopping.value == .clean)
    try await AsyncDeadline.run(seconds: 5) { await ending.value }
    #expect(!cancelled.value)
    #expect((await loop.snapshot).lastTerminal == .final("hello world"))
}

@Test func busyPressDuringEnhancingKeepsThePublishedPreRewriteFinal() async throws {
    let rewriteEntered = LockedFlag()
    let releaseRewrite = LockedFlag()
    let prompt = PromptDefinition(template: "Rewrite")
    var settings = AppSettings.defaults
    settings.prompts = [prompt]
    settings.selectedPromptID = prompt.id
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: settings, config: ProviderConfiguration(provider: .mock),
        rewriteRunner: { text, _ in
            rewriteEntered.set()
            while !releaseRewrite.value {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return "tidied \(text)"
        })
    try #require(await loop.pressBegan())
    let ending = Task { await loop.pressEnded() }
    defer {
        releaseRewrite.set()
        ending.cancel()
    }
    try await AsyncDeadline.run(seconds: 5) {
        while !rewriteEntered.value {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    let published = await loop.snapshot
    #expect(published.state == .enhancing)
    #expect(published.lastTerminal == .final("hello world"))
    // The pre-rewrite final is the take's published result: a busy press
    // during the rewrite must not replace it while the rewrite runs.
    await loop.reportBusyPress()
    let busy = await loop.snapshot
    #expect(busy.lastError == nil)
    #expect(busy.lastTerminal == .final("hello world"))
    #expect(busy.terminalRevision == published.terminalRevision)
    releaseRewrite.set()
    try await AsyncDeadline.run(seconds: 5) { await ending.value }
    #expect(inserter.inserts == ["tidied hello world "])
    #expect((await loop.snapshot).lastTerminal == .final("tidied hello world"))
}
