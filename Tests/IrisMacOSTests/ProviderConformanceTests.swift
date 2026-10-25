import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

@Test(arguments: AppProviderAssembly.defaultRegistry().availableProviders)
func assembledProviderCompletesAndUsesTypedFraming(id: ProviderID) async throws {
    let fixture = try ProviderConformanceFixture(id: id)
    let transport = ConformanceTransport(fixture)
    let client = fixture.provider.makeClient(config: fixture.config, transport: transport)
    let service = TranscriptionService(
        client: client, completion: fixture.provider.completionPolicy(for: fixture.config))
    let mismatched = ProviderConfiguration(provider: ProviderID("mismatch"))
    #expect(AppProviderAssembly.defaultRegistry().makeClient(id: id, config: mismatched, transport: transport) == nil)
    try await service.start(config: fixture.config)
    let audio = PCMFrame(samples: [1, -1])
    try await service.appendAudio(audio)
    let outcome = await service.finish()
    #expect(outcome == .completed(id == .mock ? "hello world" : "conformance"))
    if fixture.ack != nil {
        #expect(transport.didClose)
        #expect(transport.messagesWritten.contains(.binary(audio.asData())))
        #expect(
            transport.messagesWritten.contains {
                if case .text = $0 { return true }
                return false
            })
    }
}

@Test(arguments: AppProviderAssembly.defaultRegistry().availableProviders)
func assembledProviderCancellationUnblocksActiveOperations(id: ProviderID) async throws {
    let fixture = try ProviderConformanceFixture(id: id)
    let phases: [ConformancePhase] = fixture.ack == nil ? [.startup] : [.startup, .audio, .finish]
    for phase in phases {
        let transport = ConformanceTransport(fixture, blocked: phase)
        let client = fixture.provider.makeClient(config: fixture.config, transport: transport)
        if fixture.ack == nil {
            try await client.start(config: fixture.config)
            let consumer = Task { do { for try await _ in client.events() {} } catch {} }
            #expect(
                await AsyncDeadline.shutdown(seconds: 10) {
                    await client.cancel()
                    await consumer.value
                } == .clean)
            continue
        }
        if phase != .startup { try await client.start(config: fixture.config) }
        let operation = Task {
            switch phase {
            case .startup: try await client.start(config: fixture.config)
            case .audio: try await client.sendAudio(PCMFrame(samples: [1, -1]))
            case .finish: try await client.endAudio()
            case .complete: break
            }
        }
        try await AsyncDeadline.run(seconds: 10) { await transport.reached(phase) }
        #expect(await AsyncDeadline.shutdown(seconds: 10) { await client.cancel() } == .clean)
        #expect(transport.didClose)
        let result = try await AsyncDeadline.run(seconds: 10) { await operation.result }
        if case .success = result { Issue.record("Cancelled \(phase) unexpectedly succeeded for \(id.name)") }
    }
}

/// Settings edits exactly one secret per provider (`ProviderKeyEditor`
/// writes `apiKey`). A provider declaring any other secret field could never
/// have it entered, so its credentials would stay "missing" forever.
@Test(arguments: AppProviderAssembly.defaultRegistry().availableProviders)
func assembledProviderDeclaresOnlyTheEditableAPIKeySecret(id: ProviderID) throws {
    let descriptor = try #require(AppProviderAssembly.defaultRegistry().descriptor(for: id))
    #expect(descriptor.secretKeys.isSubset(of: [ProviderConfiguration.Key.apiKey]))
}
