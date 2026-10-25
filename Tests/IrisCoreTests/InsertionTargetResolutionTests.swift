import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// First target lookup parks off-actor until released; later lookups return
/// the newer target immediately.
private final class BlockingFirstTargetProvider: @unchecked Sendable {
    let entered = LockedFlag()
    let released = LockedFlag()
    private let lock = NSLock()
    private var calls = 0

    func provide() -> InsertionTargetSnapshot? {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 1 else { return InsertionTargetSnapshot(pid: 2) }
        entered.set()
        while !released.value {
            Thread.sleep(forTimeInterval: 0.002)
        }
        return InsertionTargetSnapshot(pid: 1)
    }
}

@Test func staleTargetResolutionCannotOverwriteNewerTake() async throws {
    let provider = BlockingFirstTargetProvider()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: loopConfig(),
        insertionTargetProvider: { provider.provide() })
    let firstPress = Task { await loop.pressBegan() }
    await waitForLoop("first target lookup starts") { provider.entered.value }
    let firstID = try #require(await loop.currentTake?.id)
    await loop.cancelTake(id: firstID)
    // Simulate the orphaned-cleanup barrier being superseded while the first
    // lookup remains parked, then start the take that must own the target.
    await loop.clearShutdownTask(generation: loop.shutdownGeneration)
    #expect(await loop.pressBegan())
    #expect(await loop.currentTake?.target == InsertionTargetSnapshot(pid: 2))
    provider.released.set()
    #expect(await firstPress.value == false)
    #expect(await loop.currentTake?.target == InsertionTargetSnapshot(pid: 2))
    await loop.pressEnded()
}
