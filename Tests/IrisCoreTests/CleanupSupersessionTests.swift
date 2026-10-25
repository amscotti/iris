import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func supersededCleanupTimeoutDoesNotLatchRestartOntoANewerTake() async throws {
    let gate = ManualGate()
    let watchdog = gate.watchdog()
    defer {
        watchdog.cancel()
        gate.release()
    }
    let first = HangingCancelClient(cancel: gate)
    let creations = TestValue(0)
    let loop = DictationOrchestrator(
        audio: LoopAudio(),
        makeService: { _ in
            let index = creations.update {
                $0 += 1
                return $0
            }
            return TranscriptionService(
                client: index == 1 ? first : MockTranscriptionClient(), shutdownTimeout: 0.5)
        }, config: ProviderConfiguration(provider: .mock), shutdownTimeout: 0.5)
    #expect(await loop.pressBegan())
    let stopping = Task { await loop.stop() }
    try await AsyncDeadline.run(seconds: 5) { await gate.waitUntilEntered() }
    // Model the pump-deadline path superseding and clearing this cleanup's
    // barrier while its provider join remains parked.
    let supersedingGeneration = await loop.reserveShutdownGeneration()
    await loop.clearShutdownTask(generation: supersedingGeneration)
    #expect(await loop.pressBegan())
    // Let the newer take finish before the stale cleanup is allowed to time
    // out. Without the generation clause, take == nil here would latch a
    // restart; with it, the superseded cleanup is harmless.
    await loop.pressEnded()
    #expect(await loop.currentTake == nil)
    _ = await stopping.value
    #expect(await loop.requiresRestart == false)
    #expect(await loop.currentTake == nil)
    gate.release()
}
