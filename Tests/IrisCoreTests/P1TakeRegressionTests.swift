import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func p1RegressionConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

@Test func cleanupTimeoutStillInsertsRetainedFinalBeforeRestart() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let client = HangingCancelClient(cancel: gate)
    let service = TranscriptionService(client: client, shutdownTimeout: 0.05)
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in service },
        config: p1RegressionConfig(), shutdownTimeout: 0.05)

    try #require(await loop.pressBegan())
    await loop.pressEnded()

    #expect(inserter.inserts == ["success "])
    #expect(await service.lastFinal == "success")
    #expect(await service.requiresRestart)
    let snapshot = await loop.snapshot
    #expect(snapshot.requiresRestart)
    #expect(snapshot.lastError == TranscriptionService.restartMessage)
    #expect(!snapshot.isTakeActive)
}

@Test func softTakeDeadlineFinalizesAndInsertsBeforeHardLimit() async throws {
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: p1RegressionConfig(), softTakeTimeout: 0.05)

    try #require(await loop.pressBegan())
    // No release edge: the orchestrator-owned soft deadline must drive the
    // ordinary finish/insert path before any provider stream-limit failure.
    try await AsyncDeadline.run(seconds: 5) {
        while await loop.isPressActive {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    #expect(client.finishCallCount == 1)
    #expect(inserter.inserts == ["hello world "])
    let snapshot = await loop.snapshot
    #expect(snapshot.lastError == nil)
    #expect(!snapshot.requiresRestart)
    #expect(!snapshot.isTakeActive)
}

/// A cooperative blocking worker whose late side effect is valid only if its
/// cancellation seam was not called. This isolates the orchestrator deadline
/// from the production inserter's generation checks (covered in IrisMacOSTests).
private final class P1DeadlineInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private let entered = AsyncStream.makeStream(of: Void.self)
    private let finished = AsyncStream.makeStream(of: Void.self)
    private let cancelled = LockedFlag()
    let release = DispatchSemaphore(value: 0)

    func insert(_ text: String) {
        entered.continuation.yield(())
        _ = release.wait(timeout: .now() + 10)
        if !cancelled.value {
            lock.withLock { stored.append(text) }
        }
        finished.continuation.yield(())
    }

    func cancelInsertion() {
        cancelled.set()
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilFinished() async {
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    var wasCancelled: Bool { cancelled.value }
    var inserts: [String] { lock.withLock { stored } }
}

@Test func insertionDeadlineCancelsWorkerBeforeItsLateSideEffect() async throws {
    let inserter = P1DeadlineInserter()
    defer { inserter.release.signal() }
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: p1RegressionConfig(), insertionTimeout: 0.05)

    try #require(await loop.pressBegan())
    let ending = Task { await loop.pressEnded() }
    try await AsyncDeadline.run(seconds: 5) { await inserter.waitUntilEntered() }
    try await AsyncDeadline.run(seconds: 5) { await ending.value }
    #expect(inserter.wasCancelled)
    #expect(await loop.snapshot.requiresRestart)

    inserter.release.signal()
    try await AsyncDeadline.run(seconds: 5) { await inserter.waitUntilFinished() }
    #expect(inserter.inserts.isEmpty)
}

@Test func cancelActiveTakeStopsWithoutFinalizingAndTracksSnapshot() async throws {
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        config: p1RegressionConfig())

    #expect(await loop.cancelActiveTake() == false)
    try #require(await loop.pressBegan())
    #expect(await loop.snapshot.isTakeActive)

    #expect(await loop.cancelActiveTake())
    #expect(client.finishCallCount == 0)
    #expect(inserter.inserts.isEmpty)
    let snapshot = await loop.snapshot
    #expect(!snapshot.isTakeActive)
    #expect(!snapshot.requiresRestart)
    #expect(await loop.cancelActiveTake() == false)
}

@Test func cancellationRejectsAStaleTakeID() async throws {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: p1RegressionConfig())

    try #require(await loop.pressBegan())
    let id = try #require(await loop.currentTake?.id)
    #expect(await loop.cancelActiveTake(expectedID: id + 1) == false)
    #expect(await loop.isPressActive)
    #expect(await loop.cancelActiveTake(expectedID: id))
    #expect(await loop.cancelActiveTake(expectedID: id) == false)
}
