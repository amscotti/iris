import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func coreRegistryHasNoImplicitProviderAssembly() {
    let registry = ProviderRegistry()
    #expect(registry.availableProviders.isEmpty)
    #expect(registry.rewriters.isEmpty)
    #expect(
        registry.makeClient(id: .meta, config: ProviderConfiguration(provider: .meta), transport: TestTransport())
            == nil)
}

@Test func providerMigrationsBelongToTheRepositoryNotValueDecoding() throws {
    let data = Data(
        #"{"providerName":"Grok","prompts":[{"id":"77777777-7777-7777-7777-777777777777","template":"keep","model":"grok-custom","effort":"high"}]}"#
            .utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.providerConfigs.isEmpty)
    let store = MemoryPersistence()
    try store.save(data, forKey: AppSettings.storageKey)
    let migrated = try AppSettings.load(from: store, registry: testProviderRegistry())
    #expect(migrated.providerConfigs["Grok"]?["rewriteModel"] == "grok-custom")
    #expect(migrated.prompts.map(\.template) == decoded.prompts.map(\.template))
    #expect(migrated.schemaVersion == AppSettings.currentSchemaVersion)
}

@Test func cancellingOrchestratorObservationReleasesItsSubscription() async {
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock))
    let stream = await loop.states()
    let consumer = Task { for await _ in stream {} }
    #expect(await loop.subscriberCount == 1)
    consumer.cancel()
    await consumer.value
    #expect(await loop.subscriberCount == 0)
}

@Test func slowTerminalObserverDoesNotLoseCompletedTakes() async {
    let loop = DictationOrchestrator(
        audio: LoopAudio(), makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock))
    let events = await loop.terminalEvents()
    for _ in 0..<3 {
        await loop.pressBegan()
        await loop.pressEnded()
    }
    var iterator = events.makeAsyncIterator()
    for _ in 0..<3 { #expect(await iterator.next() == .final("hello world")) }
}

@Test func jsonLookingPCMIsStillSentAsBinary() async throws {
    let transport = TestTransport(serverFrames: [Data(#"{"type":"transcript.created"}"#.utf8)], deliverCount: 1)
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: ProviderConfiguration(provider: .grok, values: ["apiKey": "fixture"]))
    let frame = PCMFrame(samples: [0x7D7B])
    #expect(frame.asData() == Data("{}".utf8))
    try await client.sendAudio(frame)
    #expect(transport.messagesWritten == [.binary(Data("{}".utf8))])
    await client.cancel()
}
