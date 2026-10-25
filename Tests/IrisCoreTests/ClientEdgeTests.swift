import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Transport whose writes always fail, for the handshake-failure path.
final class ThrowingTransport: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    func connect() async throws {}

    func write(_ message: TransportMessage) async throws {
        throw NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "pipe down"])
    }

    func close() async {
        locked { closed = true }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func messages() -> AsyncThrowingStream<TransportMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    var didClose: Bool {
        locked { closed }
    }
}

private func edgeJSON(_ text: String) -> Data { Data(text.utf8) }

private let edgeAck = edgeJSON(#"{"sessionId":"s-1"}"#)
private let edgePartial = edgeJSON(#"{"type":"transcript","transcript":"hel","final":false}"#)

private func edgeConfig() -> ProviderConfiguration {
    ProviderConfiguration(
        provider: .meta, values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ"])
}

@Test func audioBeforeStartThrowsInvalidState() async {
    let client = MetaVoiceTranscribeClient(transport: TestTransport())
    await #expect(throws: TranscriptionError(kind: .invalidState, message: "Audio sent outside an active session.")) {
        try await client.sendAudio(PCMFrame(samples: [1, -1]))
    }
}

@Test func handshakeWriteFailureResetsToIdle() async throws {
    let transport = ThrowingTransport()
    let client = MetaVoiceTranscribeClient(transport: transport)
    do {
        try await client.start(config: edgeConfig())
        Issue.record("Expected a handshake throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .network)
        #expect(failure.message == "Handshake write failed: pipe down")
    }
    await #expect(throws: TranscriptionError(kind: .invalidState, message: "Audio sent outside an active session.")) {
        try await client.sendAudio(PCMFrame(samples: [1, -1]))
    }
    #expect(transport.didClose)
}

@Test func preAckFramesAreIgnoredUntilTheAck() async throws {
    let transport = TestTransport(serverFrames: [edgePartial, edgeAck])
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: edgeConfig())
    #expect(transport.didConnect)
    #expect(transport.writes.count == 1)
}

@Test func closeBeforeAckIsAServerClosedError() async throws {
    let transport = TestTransport(serverFrames: [])
    let client = MetaVoiceTranscribeClient(transport: transport)
    do {
        try await client.start(config: edgeConfig())
        Issue.record("Expected a server-closed throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .serverClosed)
    }
    #expect(transport.didClose)
}

@Test func finishWithoutStartThrowsInvalidState() async throws {
    let client = MetaVoiceTranscribeClient(transport: TestTransport())
    do {
        for try await _ in client.finish() {}
        Issue.record("Expected an invalid-state throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .invalidState)
    }
}

@Test func drainErrorEventYieldsThenThrows() async throws {
    let transport = TestTransport(serverFrames: [
        edgeAck, edgeJSON(#"{"type":"error","code":401,"message":"bad key"}"#),
    ])
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: edgeConfig())
    var events: [TranscriptionEvent] = []
    do {
        for try await event in client.finish() {
            events.append(event)
        }
        Issue.record("Expected an auth throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
    }
    #expect(events == [.error(TranscriptionError(kind: .authentication, message: "bad key"))])
}

@Test func drainSkipsUnrecognizedFrames() async throws {
    let transport = TestTransport(serverFrames: [
        edgeAck, edgeJSON(#"{"type":"heartbeat"}"#),
        edgeJSON(#"{"type":"transcript","transcript":"hello","final":true}"#),
    ])
    let client = MetaVoiceTranscribeClient(transport: transport)
    try await client.start(config: edgeConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() {
        events.append(event)
    }
    #expect(events == [.final("hello")])
}

@Test func endpointOmitsBlankSessionId() {
    let blank = MetaVoiceTranscribeClient.endpointURL(sessionId: "")
    #expect(!blank.absoluteString.contains("sessionId"))
}

/// Client whose `endAudio` closes the transport without re-yielding: live
/// events queued before `finish()` must still survive the close.
final class CloseOnEndAudioClient: TranscriptionClient, @unchecked Sendable {
    private let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    private let terminalError: Error?

    init(terminalError: Error? = nil) { self.terminalError = terminalError }

    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        if let terminalError {
            channel.continuation.finish(throwing: terminalError)
        } else {
            channel.continuation.finish()
        }
    }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }

    func emitLive(_ events: [TranscriptionEvent]) {
        for event in events { channel.continuation.yield(event) }
    }
}

@Test func finishPreservesLiveEventsWhenEndAudioClosesTransport() async throws {
    let client = CloseOnEndAudioClient()
    client.emitLive([.partial("hello"), .final("hello world")])
    var seen: [TranscriptionEvent] = []
    for try await event in client.finish() { seen.append(event) }
    #expect(seen == [.partial("hello"), .final("hello world")])
}

@Test func finishPreservesLiveErrorWhenEndAudioClosesTransport() async throws {
    struct Boom: Error {}
    let client = CloseOnEndAudioClient(terminalError: Boom())
    client.emitLive([.error(TranscriptionError(kind: .network, message: "queued"))])
    var seen: [TranscriptionEvent] = []
    do {
        for try await event in client.finish() { seen.append(event) }
    } catch is Boom {
    } catch {
        Issue.record("Expected Boom, got \(error)")
    }
    #expect(seen == [.error(TranscriptionError(kind: .network, message: "queued"))])
}
