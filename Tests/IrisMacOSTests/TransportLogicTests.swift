import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

private final class LockingQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data]

    init(items: [Data]) { self.items = items }

    func pop() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

@Test func handshakeRequestCarriesAuthorizationHeaders() {
    let url = GrokVoiceTranscribeClient.endpointURL()
    let request = URLSessionWebSocketTransport.handshakeRequest(
        url: url, headers: ["Authorization": "Bearer grok-key"])
    #expect(request.url == url)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-key")
    let bare = URLSessionWebSocketTransport.handshakeRequest(url: url, headers: [:])
    #expect(bare.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func upgradeAuthorizationHeaderRejectsHeaderDelimiterKeys() {
    // CFNetwork drops an Authorization header containing CR/LF entirely,
    // silently downgrading the upgrade to unauthenticated; refuse it first.
    let bad = URLSessionWebSocketTransport.authorizationHeaderFailure(
        headers: ["Authorization": "Bearer key\r\nX-Forged: 1"])
    #expect(bad?.isAuthFailure == true)
    #expect(bad?.message == TranscriptionError.invalidAPIKeyCharactersMessage)
    let nul = URLSessionWebSocketTransport.authorizationHeaderFailure(
        headers: ["Authorization": "Bearer key\u{0}"])
    #expect(nul?.isAuthFailure == true)
    #expect(
        URLSessionWebSocketTransport.authorizationHeaderFailure(headers: ["Authorization": "Bearer ok"]) == nil)
    #expect(URLSessionWebSocketTransport.authorizationHeaderFailure(headers: [:]) == nil)
    // Other headers ride untouched; only the auth-bearing value is guarded.
    #expect(
        URLSessionWebSocketTransport.authorizationHeaderFailure(headers: ["X-Session": "a\r\nb"]) == nil)
}

@Test func writeBeforeConnectThrowsInvalidState() async {
    let transport = URLSessionWebSocketTransport(
        url: MetaVoiceTranscribeClient.endpointURL(sessionId: "test"))
    await #expect(
        throws: TranscriptionError(kind: .invalidState, message: "WebSocket write before connect.")
    ) {
        try await transport.write(Data([0x01]))
    }
}

@Test func frameReceiveLoopYieldsThenFinishesOnNil() async throws {
    let stream = AsyncThrowingStream<TransportMessage, Error> { continuation in
        let remaining = LockingQueue(items: [Data([1]), Data([2])])
        _ = MessageReceiveLoop.start(continuation: continuation) {
            remaining.pop().map(TransportMessage.binary)
        }
    }
    var collected: [Data] = []
    for try await frame in stream {
        collected.append(frame.data)
    }
    #expect(collected == [Data([1]), Data([2])])
}

@Test func frameReceiveLoopMapsBufferOverflowToNetworkError() async {
    let stream = AsyncThrowingStream<TransportMessage, Error>(bufferingPolicy: .bufferingOldest(1)) {
        continuation in
        _ = MessageReceiveLoop.start(continuation: continuation) {
            TransportMessage.text("x")
        }
    }
    // Let the unbounded producer fill the size-1 oldest buffer so a
    // subsequent yield returns `.dropped` before the consumer attaches.
    try? await Task.sleep(nanoseconds: 100_000_000)
    var caught: Error?
    do {
        for try await _ in stream {
        }
    } catch {
        caught = error
    }
    #expect(
        (caught as? TranscriptionError)
            == TranscriptionError(
                kind: .network, message: "Speech transport buffer overflow; please retry."))
}

@Test func messagesBeforeConnectEndsImmediately() async throws {
    let transport = URLSessionWebSocketTransport(
        url: MetaVoiceTranscribeClient.endpointURL(sessionId: "test"))
    var count = 0
    for try await _ in transport.messages() {
        count += 1
    }
    #expect(count == 0)
}

@Test func closeIsIdempotent() async {
    let transport = URLSessionWebSocketTransport(
        url: MetaVoiceTranscribeClient.endpointURL(sessionId: "test"))
    await transport.close()
    await transport.close()
}

// MARK: - receiveFailure matrix

private func urlError(code: Int, description: String, responseStatus: Int? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let status = responseStatus {
        userInfo["testResponse"] =
            HTTPURLResponse(
                url: URL(string: "wss://example.test/")!, statusCode: status,
                httpVersion: nil, headerFields: nil) as Any
    }
    return NSError(domain: NSURLErrorDomain, code: code, userInfo: userInfo)
}

@Test func receiveFailurePrefersExplicitStatusCode() {
    let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let auth = URLSessionWebSocketTransport.receiveFailure(timeout, statusCode: 401)
    #expect((auth as? TranscriptionError)?.isAuthFailure == true)
    let limited = URLSessionWebSocketTransport.receiveFailure(timeout, statusCode: 429)
    #expect((limited as? TranscriptionError)?.kind == .rateLimited)
    let timedOut = URLSessionWebSocketTransport.receiveFailure(timeout, statusCode: nil)
    #expect((timedOut as? TranscriptionError)?.kind == .timeout)
}

@Test func receiveFailureFallsBackToNSErrorWhenStatusIsNil() {
    let auth = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: 401, description: "unauthorized"), statusCode: nil)
    #expect((auth as? TranscriptionError)?.isAuthFailure == true)
    let worded = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorCannotConnectToHost, description: "not authenticated"),
        statusCode: nil)
    #expect((worded as? TranscriptionError)?.isAuthFailure == true)
    let keyed = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorCannotConnectToHost, description: "Invalid API key"),
        statusCode: nil)
    #expect((keyed as? TranscriptionError)?.isAuthFailure == true)
    let limited = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorCannotConnectToHost, description: "quota exceeded"),
        statusCode: nil)
    #expect((limited as? TranscriptionError)?.kind == .rateLimited)
    let numeric = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorCannotConnectToHost, description: "HTTP 429 too many requests"),
        statusCode: nil)
    #expect((numeric as? TranscriptionError)?.kind == .rateLimited)
}

@Test func receiveFailureReadsEmbeddedHTTPResponse() {
    let auth = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorCannotConnectToHost, description: "upgrade failed", responseStatus: 403),
        statusCode: nil)
    #expect((auth as? TranscriptionError)?.isAuthFailure == true)
}

@Test func receiveFailureMapsDroppedConnectionToServerClosed() {
    let closed = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorNetworkConnectionLost, description: "Network connection was lost."),
        statusCode: nil)
    #expect((closed as? TranscriptionError)?.kind == .serverClosed)
}

@Test func receiveFailureIgnoresAuthDigitsInTheFailingURL() {
    // A session id or keyterm URL can contain digit runs like "401"; the
    // dropped-connection mapping must win over any text heuristic.
    let dropped = NSError(
        domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
        userInfo: [
            NSLocalizedDescriptionKey: "Network connection was lost.",
            "NSErrorFailingURLStringKey": "wss://api.meta.ai/v1/asr/realtime?sessionId=3F4019C2-8A41",
        ])
    let mapped = URLSessionWebSocketTransport.receiveFailure(dropped, statusCode: nil)
    #expect((mapped as? TranscriptionError)?.kind == .serverClosed)
}

@Test func transportHeuristicsRequireAuthWordsNotBareStatusDigits() {
    #expect(TranscriptionError.classifiedTransportError(in: "Room 401 is not available") == nil)
    #expect(TranscriptionError.classifiedTransportError(in: "table 429") == nil)
    #expect(TranscriptionError.classifiedTransportError(in: "unauthorized")?.kind == .authentication)
    #expect(TranscriptionError.classifiedTransportError(in: "HTTP 429 too many requests")?.kind == .rateLimited)
    let wordy = URLSessionWebSocketTransport.receiveFailure(
        urlError(code: NSURLErrorCannotConnectToHost, description: "Room 401 is not available"),
        statusCode: nil)
    // No auth classification: the raw error may pass through or get a
    // non-auth kind; what must never happen is isAuthFailure.
    #expect(!((wordy as? TranscriptionError)?.isAuthFailure ?? false))
}

@Test func receiveFailureMapsPOSIXSocketCloseToServerClosed() {
    // A server-initiated websocket close surfaces from receive() as a POSIX
    // socket error on current macOS, not as -1005. Pin both the set and the
    // literal codes so a regression in either is caught.
    #expect(URLSessionWebSocketTransport.posixCloseCodes == [57, 54, 32])
    for code in [57, 54, 32] {  // ENOTCONN, ECONNRESET, EPIPE
        let error = NSError(domain: NSPOSIXErrorDomain, code: code)
        let mapped = URLSessionWebSocketTransport.receiveFailure(error, statusCode: nil)
        #expect((mapped as? TranscriptionError)?.kind == .serverClosed)
    }
    let unrelated = NSError(domain: NSPOSIXErrorDomain, code: 13)  // EACCES
    let passed = URLSessionWebSocketTransport.receiveFailure(unrelated, statusCode: nil)
    #expect((passed as? TranscriptionError)?.kind != .serverClosed)
}

@Test func receiveFailurePassesThroughCategorizedErrors() {
    let known = TranscriptionError(kind: .rateLimited, message: "slow down")
    let mapped = URLSessionWebSocketTransport.receiveFailure(known, statusCode: nil)
    #expect((mapped as? TranscriptionError) == known)
}

// MARK: - Client transport-error mapping

@Test func metaTransportErrorsMapUnauthorizedToAuth() {
    let error = NSError(
        domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
        userInfo: [NSLocalizedDescriptionKey: "unauthorized 401"])
    #expect(MetaVoiceTranscribeClient.classifyTransportError(error).isAuthFailure)
    let known = TranscriptionError(kind: .timeout, message: "slow")
    #expect(MetaVoiceTranscribeClient.classifyTransportError(known) == known)
}

// MARK: - Typed framing

@Test func codecsIgnoreBinaryControlFrames() throws {
    let grokAck = Data(#"{"type":"transcript.created"}"#.utf8)
    var grok = try GrokSpeechCodec()
    let grokAckText = try #require(String(data: grokAck, encoding: .utf8))
    #expect(!grok.isReady(.binary(grokAck)))
    #expect(grok.isReady(.text(grokAckText)))
    #expect(
        grok.decode(.binary(Data(#"{"type":"transcript.partial","text":"hi"}"#.utf8))) == nil)

    let session = MetaSessionConfig(apiKey: "k", audioEncoding: .pcm16k)
    let meta = try MetaSpeechCodec(session: session)
    let ack = Data(#"{"sessionId":"s-1"}"#.utf8)
    let ackText = try #require(String(data: ack, encoding: .utf8))
    #expect(!meta.isReady(.binary(ack)))
    #expect(meta.isReady(.text(ackText)))
    #expect(
        meta.decode(.binary(Data(#"{"type":"transcript","transcript":"hi"}"#.utf8))) == nil)
}

// MARK: - Accumulator untimed fallback

@Test func accumulatorDedupsUntimedResends() {
    var transcript = GrokTranscriptAccumulator()
    let first = transcript.append(text: "hello", start: nil, duration: nil, isFinal: true, speechFinal: false)
    #expect(first == "hello")
    let second = transcript.append(text: "hello wo", start: nil, duration: nil, isFinal: false, speechFinal: false)
    #expect(second == "hello wo")
}

@Test func accumulatorKeepsDistinctUntimedSegments() {
    var transcript = GrokTranscriptAccumulator()
    _ = transcript.append(text: "hello", start: nil, duration: nil, isFinal: true, speechFinal: false)
    let combined = transcript.append(
        text: "world", start: nil, duration: nil, isFinal: true, speechFinal: false)
    #expect(combined == "hello world")
}

// MARK: - Language allowlist on the wire

@Test func unknownGrokLanguageOmitsQueryItem() {
    let url = GrokVoiceTranscribeClient.endpointURL(
        from: ProviderConfiguration(provider: .grok, values: ["apiKey": "k", "languageBias": "nope"]))
    #expect(url.query?.contains("language=") != true)
}

@Test func unknownMetaLanguageBiasIsDropped() {
    #expect(MetaLanguageBias.wireValues(from: "Klingon") == [])
    #expect(MetaLanguageBias.selection(from: "Klingon") == MetaLanguageBias.auto)
    #expect(MetaLanguageBias.wireValues(from: "en, Klingon") == ["English"])
}

// MARK: - Tolerant JSON coercions

@Test func stringErrorCodesClassifyAsAuth() {
    let grok = GrokWireProtocol.decodeServerEvent(
        Data(#"{"type":"error","code":"401","message":"bad key"}"#.utf8))
    if case .error(let failure) = grok {
        #expect(failure.isAuthFailure)
    } else {
        Issue.record("Expected a Grok error event")
    }
    let meta = MetaWireProtocol.decodeServerEvent(
        Data(#"{"type":"error","code":"429","message":"slow"}"#.utf8))
    #expect(meta == .error(TranscriptionError(kind: .rateLimited, message: "slow")))
}

@Test func numericFinalFlagsComplete() {
    let grok = GrokWireProtocol.decodeServerEvent(
        Data(#"{"type":"transcript.partial","text":"hi","is_final":1}"#.utf8))
    #expect(grok == .partial("hi"))
    let meta = MetaWireProtocol.decodeServerEvent(
        Data(#"{"type":"transcript","transcript":"hello","final":1}"#.utf8))
    #expect(meta == .final("hello"))
    let worded = MetaWireProtocol.decodeServerEvent(
        Data(#"{"type":"transcript","transcript":"hello","final":"true"}"#.utf8))
    #expect(worded == .final("hello"))
}

@Test func receiveFailureMapsDocumentedCloseCodes() {
    let dropped = NSError(domain: NSPOSIXErrorDomain, code: 57)
    let limited = URLSessionWebSocketTransport.receiveFailure(dropped, statusCode: nil, closeCode: 1013)
    #expect((limited as? TranscriptionError)?.kind == .rateLimited)
    let rejected = URLSessionWebSocketTransport.receiveFailure(dropped, statusCode: nil, closeCode: 1008)
    #expect((rejected as? TranscriptionError)?.kind == .invalidState)
    let serverEnded = URLSessionWebSocketTransport.receiveFailure(dropped, statusCode: nil, closeCode: 1011)
    #expect((serverEnded as? TranscriptionError)?.kind == .streamLimit)
    // Ordinary closes keep the previous generic mapping.
    let gone = URLSessionWebSocketTransport.receiveFailure(dropped, statusCode: nil, closeCode: 1000)
    #expect((gone as? TranscriptionError)?.kind == .serverClosed)
}
