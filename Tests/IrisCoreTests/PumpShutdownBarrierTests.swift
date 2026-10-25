import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func pumpCompletionDoesNotReplaceAnExistingShutdownBarrier() async throws {
    let client = WedgedTransportClient()
    defer { client.releaseGates() }
    let inserter = SlowInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client, shutdownTimeout: 0.05) },
        config: regressionConfig(), shutdownTimeout: 0.05, insertionTimeout: 0.05, pumpTimeout: 0.1)
    try #require(await loop.pressBegan())
    try await AsyncDeadline.run(seconds: 5) { await client.waitUntilParked() }
    client.channel.continuation.yield(.final("spoken words"))
    let ending = Task { await loop.pressEnded() }
    try await AsyncDeadline.run(seconds: 5) {
        while !inserter.started.value { await Task.yield() }
    }
    let stopping = Task { await loop.stop() }
    try await AsyncDeadline.run(seconds: 5) {
        while await loop.shutdownTask == nil { await Task.yield() }
    }
    let barrierGeneration = await loop.shutdownGeneration

    inserter.released.set()
    _ = await stopping.value
    _ = await ending.value

    #expect(await loop.shutdownGeneration == barrierGeneration)
    #expect(await loop.snapshot.requiresRestart)
    #expect(inserter.completed.value)
}
