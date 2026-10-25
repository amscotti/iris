import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private let closeCodeAck = Data(#"{"sessionId":"s-1"}"#.utf8)
private let closeCodeTurn = Data(
    #"{"type":"speechComplete","turnId":1,"transcript":"hello"}"#.utf8)

private func closeCodeConfig() -> ProviderConfiguration {
    ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "mode": "ENDPOINTING"])
}

private func closeCodeClient(_ closeCode: Int) -> MetaVoiceTranscribeClient {
    MetaVoiceTranscribeClient(
        transport: TestTransport(
            serverFrames: [closeCodeAck, closeCodeTurn],
            closeError: TranscriptionError.closed("socket closed", closeCode: closeCode)))
}

@Test func endpointingAbnormalCloseAfterEndStreamFails() async throws {
    let client = closeCodeClient(1006)
    try await client.start(config: closeCodeConfig())
    do {
        for try await _ in client.finish() {}
        Issue.record("An abnormal socket drop must not complete the take")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .serverClosed)
        #expect(failure.closeCode == 1006)
        #expect(!failure.isNormalClosure)
    }
}

@Test func endpointingNormalCloseAfterEndStreamCompletes() async throws {
    let client = closeCodeClient(1000)
    try await client.start(config: closeCodeConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(events == [.speechComplete(turnId: "1", transcript: "hello")])
}

@Test func socketClassificationPreservesCloseCodeAndLegacyCloseSemantics() {
    let dropped = NSError(domain: NSPOSIXErrorDomain, code: 54)
    let abnormal = TranscriptionError.classifiedSocketError(dropped, closeCode: 1006)
    #expect(abnormal?.kind == .serverClosed)
    #expect(abnormal?.closeCode == 1006)
    #expect(abnormal?.isNormalClosure == false)

    let normal = TranscriptionError.classifiedSocketError(dropped, closeCode: 1000)
    #expect(normal?.closeCode == 1000)
    #expect(normal?.isNormalClosure == true)
    #expect(TranscriptionError.closed("going away", closeCode: 1001).isNormalClosure)

    let legacy = TranscriptionError.classifiedSocketError(dropped)
    #expect(legacy == TranscriptionError.closed(TranscriptionError.transportDisconnectedMessage))
    #expect(legacy?.isNormalClosure == true)
    #expect(
        TranscriptionError.closed("same", closeCode: 1000)
            == TranscriptionError.closed("same", closeCode: 1006))
    #expect(
        Set([TranscriptionError.closed("same", closeCode: 1000)]).contains(
            TranscriptionError.closed("same", closeCode: 1006)))
}
