import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func json(_ text: String) -> Data { Data(text.utf8) }

private let ack = json(#"{"sessionId":"s-1"}"#)
private let partial = json(#"{"type":"transcript","transcript":"hel","final":false}"#)
private let final = json(#"{"type":"transcript","transcript":"hello","final":true}"#)

private func clientConfig() -> ProviderConfiguration {
    ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "sessionId": "s-1"])
}

private func handshakePayload(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TranscriptionError(kind: .decoding, message: "Expected a JSON object.")
    }
    return value
}

@Test func handshakeThenStreamThenEndStream() async throws {
    let transport = TestTransport(serverFrames: [ack, partial, final])
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: clientConfig())
    #expect(transport.didConnect)
    #expect(transport.writes.count == 1)
    let handshake = try handshakePayload(transport.writes[0])
    #expect((handshake["authorization"] as? [String: String])?["accessToken"] == "Bearer k")
    #expect(handshake["audioEncoding"] as? String == "PCM_16KHZ")

    let frame = PCMFrame(samples: [7, -7, 7, -7])
    try await client.sendAudio(frame)
    #expect(transport.writes.count == 2)
    #expect(transport.writes[1] == frame.asData())

    var events: [TranscriptionEvent] = []
    for try await event in client.finish() {
        events.append(event)
    }
    #expect(events == [.partial("hel"), .final("hello")])
    let endStream = String(data: transport.writes.last ?? Data(), encoding: .utf8) ?? ""
    #expect(endStream.contains("endStream"))
}

@Test func metaCompletionDoesNotWaitForTheServerToClose() async throws {
    let transport = TestTransport(serverFrames: [ack, final], deliverCount: 2)
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: clientConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(events == [.final("hello")])
    #expect(transport.didClose)
}

@Test func metaCompletionDiscardsLateServerErrors() async throws {
    let transport = TestTransport(serverFrames: [ack, final, json(#"{"type":"error","message":"late close"}"#)])
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: clientConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(events == [.final("hello")])
    #expect(transport.didClose)
}

@Test func authFailureThrowsWithoutRetry() async throws {
    let transport = TestTransport(serverFrames: [
        json(#"{"type":"error","code":401,"message":"bad key"}"#)
    ])
    let client = MetaVoiceTranscribeClient(transport: transport)
    do {
        try await client.start(config: clientConfig())
        Issue.record("Expected an auth throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
    }
}

@Test func closeWithoutCompletionThrows() async throws {
    let transport = TestTransport(serverFrames: [ack])
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: clientConfig())
    do {
        for try await _ in client.finish() {}
        Issue.record("Expected a server-closed throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .serverClosed)
    }
}

@Test func endpointingCompletesWhenTheServerCloseArrivesAsAnError() async throws {
    // Real sockets surface a server close from `receive()` as an error
    // (ENOTCONN), not a clean stream end. For completesOnClose codecs that
    // close after the end marker is the documented completion signal.
    let transport = TestTransport(
        serverFrames: [
            ack,
            json(#"{"type":"speechComplete","turnId":1,"transcript":"hello"}"#),
            json(#"{"type":"speechComplete","turnId":2,"transcript":"world"}"#),
        ],
        closeError: TranscriptionError.closed("The speech service disconnected before finishing. Try again."))
    let client = MetaVoiceTranscribeClient(transport: transport)
    let config = ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "mode": "ENDPOINTING"])
    try await client.start(config: config)
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(
        events == [
            .speechComplete(turnId: "1", transcript: "hello"),
            .speechComplete(turnId: "2", transcript: "world"),
        ])
}

@Test func pushToTalkStillFailsWhenTheServerCloseArrivesAsAnError() async throws {
    let transport = TestTransport(serverFrames: [ack], closeError: TranscriptionError.closed("boom"))
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: clientConfig())
    do {
        for try await _ in client.finish() {}
        Issue.record("Expected a server-closed throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .serverClosed)
    }
}

@Test func finishWaitsBoundedOnSilentServer() async throws {
    let transport = TestTransport(serverFrames: [ack], deliverCount: 1)
    let client = MetaVoiceTranscribeClient(transport: transport, finishTimeout: 0.5)
    try await client.start(config: clientConfig())
    let start = Date()
    do {
        for try await _ in client.finish() {}
        Issue.record("Expected a timeout throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .timeout)
    }
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func endpointCarriesSessionId() {
    let withId = MetaVoiceTranscribeClient.endpointURL(sessionId: "abc")
    #expect(withId.absoluteString.contains("sessionId=abc"))
    let bare = MetaVoiceTranscribeClient.endpointURL(sessionId: nil)
    #expect(!bare.absoluteString.contains("sessionId"))
}

@Test func connectionAndHandshakeShareOneSessionIdPerPress() throws {
    func handshakeSessionId(_ config: ProviderConfiguration) throws -> String? {
        let payload = try handshakePayload(
            MetaWireProtocol.encodeHandshake(config: try MetaSessionConfig(from: config)))
        return payload["sessionId"] as? String
    }
    func urlSessionId(_ config: ProviderConfiguration) throws -> String? {
        let connection = try #require(MetaProvider().connection(for: config))
        let items = URLComponents(url: connection.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "sessionId" }?.value
    }
    // Secret-backed: both doors carry the configured id, never a second minted one.
    let secret = ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "sessionId": "legacy-session"])
    #expect(try urlSessionId(secret) == "legacy-session")
    #expect(try handshakeSessionId(secret) == "legacy-session")
    // Fresh: neither door invents an id the other door cannot corroborate.
    let fresh = ProviderConfiguration(provider: .meta, values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ"])
    #expect(try urlSessionId(fresh) == nil)
    #expect(try handshakeSessionId(fresh) == nil)
}

@Test func endpointingServerCloseBeforeTheEndMarkerStillFails() async throws {
    let transport = TestTransport(serverFrames: [ack])
    let client = MetaVoiceTranscribeClient(transport: transport)
    let config = ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "mode": "ENDPOINTING"])
    try await client.start(config: config)
    // The socket dies while still recording (before endStream): that is a
    // dropped session, not the documented close-after-flush completion.
    transport.emitFailure(TranscriptionError.closed("dropped mid-stream"))
    do {
        for try await _ in client.finish() {}
        Issue.record("Expected a server-closed failure before the end marker")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .serverClosed)
    }
}
