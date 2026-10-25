import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Audio source that ends immediately, for control-path tests.
final class StillAudio: AudioCapturing, @unchecked Sendable {
    func frames() -> AsyncStream<PCMFrame> {
        AsyncStream { $0.finish() }
    }

}

/// Inserter that drops text, for control-path tests.
final class NullInserter: TextInserting, @unchecked Sendable {
    func insert(_ text: String) {}
}

/// Lock-guarded flag for hook assertions.
final class EnderFlag: @unchecked Sendable {
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

private func controlConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

@Test func updateAppliesTrailingSpaceOnNextInsert() async {
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: StillAudio(),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: controlConfig())
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(inserter.inserts == ["hello world "])
    var updated = AppSettings.defaults
    updated.trailingSpace = false
    await loop.update(settings: updated, config: controlConfig())
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(inserter.inserts == ["hello world ", "hello world"])
    #expect(await loop.isPressActive == false)
}

@Test func serviceStartFailureAbandonsThePress() async {
    let ended = EnderFlag()
    let loop = DictationOrchestrator(
        audio: StillAudio(),
        inserter: NullInserter(),
        makeService: { _ in
            TranscriptionService(
                client: FailingStartClient(
                    error: TranscriptionError(kind: .network, message: "down")))
        },
        settings: .defaults,
        config: controlConfig(),
        pressEnder: { ended.set() })
    await loop.pressBegan()
    #expect(await loop.isPressActive == false)
    #expect(ended.value)
}

@Test func stopCancelsAnActivePress() async {
    let loop = DictationOrchestrator(
        audio: StillAudio(),
        inserter: NullInserter(),
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: controlConfig())
    await loop.pressBegan()
    await loop.stop()
    #expect(await loop.isPressActive == false)
    await loop.stop()
    #expect(await loop.isPressActive == false)
}

@Test func mockClientExposesInspectionState() async throws {
    let client = MockTranscriptionClient()
    #expect(client.finishError == nil)
    #expect(client.startCallCount == 0)
    #expect(client.finishCallCount == 0)
    #expect(client.lastConfig == nil)
    #expect(client.receivedFrameCount == 0)
    let config = ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
    try await client.start(config: config)
    try await client.sendAudio(PCMFrame(samples: [1, -1]))
    #expect(client.startCallCount == 1)
    #expect(client.lastConfig == config)
    #expect(client.receivedFrameCount == 1)
    try await client.endAudio()
    #expect(client.finishCallCount == 1)
    #expect(MockTranscriptionClient.Script().partials == ["hello", "hello world"])
    #expect(MockTranscriptionClient.Script().final == "hello world")
    #expect(MockTranscriptionClient.Script.emptyFinal.final.isEmpty)
}
