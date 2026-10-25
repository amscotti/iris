import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func grokFrame(_ text: String) -> Data { Data(text.utf8) }

private let grokCreated = grokFrame(#"{"type":"transcript.created"}"#)
private let grokPartial = grokFrame(#"{"type":"transcript.partial","text":"hel","is_final":false}"#)
private let grokDone = grokFrame(#"{"type":"transcript.done","text":"hello","duration":1.1}"#)

private func grokConfig(values: [String: String] = ["apiKey": "k"]) -> ProviderConfiguration {
    ProviderConfiguration(provider: .grok, values: values)
}

@Test func grokStreamsAfterCreatedThenAudioDone() async throws {
    let transport = TestTransport(serverFrames: [grokCreated, grokPartial, grokDone])
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: grokConfig())
    #expect(transport.didConnect)
    #expect(transport.writes.isEmpty)

    let frame = PCMFrame(samples: [7, -7, 7, -7])
    try await client.sendAudio(frame)
    #expect(transport.writes == [frame.asData()])

    var events: [TranscriptionEvent] = []
    for try await event in client.finish() {
        events.append(event)
    }
    #expect(events == [.partial("hel"), .final("hello")])
    #expect(String(data: transport.writes.last ?? Data(), encoding: .utf8) == #"{"type":"audio.done"}"#)
    #expect(transport.didClose)
}

@Test func grokMissingKeyThrowsAuthWithoutConnecting() async throws {
    let transport = TestTransport(serverFrames: [grokCreated])
    let client = GrokVoiceTranscribeClient(transport: transport)
    do {
        try await client.start(config: grokConfig(values: [:]))
        Issue.record("Expected an auth throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
    }
    #expect(!transport.didConnect)
}

@Test func grokCompletionDoesNotWaitForSocketClose() async throws {
    let transport = TestTransport(serverFrames: [grokCreated, grokDone], deliverCount: 2)
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: grokConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(events == [.final("hello")])
    #expect(transport.didClose)
}

@Test func grokEmptyDonePreservesCompletedUtterances() async throws {
    let transport = TestTransport(serverFrames: [
        grokCreated,
        grokFrame(
            #"{"type":"transcript.partial","text":"Hello there.","start":0,"duration":2,"is_final":true,"speech_final":true}"#
        ),
        grokFrame(
            #"{"type":"transcript.partial","text":"Second sentence.","start":3,"duration":2,"is_final":true,"speech_final":true}"#
        ),
        grokFrame(#"{"type":"transcript.done","text":"","duration":5}"#),
    ])
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: grokConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(events.last == .final("Hello there. Second sentence."))
}

@Test func grokStitchedUtteranceReplacesChunkFinals() {
    var transcript = GrokTranscriptAccumulator()
    for frame in [
        #"{"type":"transcript.partial","text":"One","start":0,"duration":1,"is_final":true}"#,
        #"{"type":"transcript.partial","text":"two","start":1,"duration":1,"is_final":true}"#,
        #"{"type":"transcript.partial","text":"One, two.","start":0,"duration":2,"is_final":true,"speech_final":true}"#,
        #"{"type":"transcript.partial","text":"Three.","start":3,"duration":1,"is_final":false}"#,
    ] {
        _ = GrokWireProtocol.decodeServerEvent(grokFrame(frame), accumulating: &transcript)
    }
    #expect(
        GrokWireProtocol.decodeServerEvent(
            grokFrame(#"{"type":"transcript.done","duration":4}"#), accumulating: &transcript)
            == .final("One, two. Three."))
}

@Test func untimedPrefixMustEndAtAWordBoundary() {
    // "no" and "nobody knows" are distinct words, not a cumulative resend:
    // both must survive rather than silently deleting one.
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"No","is_final":true}"#), accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"Nobody knows","is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.textSoFar == "No Nobody knows")
}

@Test func shorterUntimedInterimCannotEraseACommittedSegment() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"the cat","is_final":true}"#), accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"the","is_final":false}"#), accumulating: &transcript)
    #expect(transcript.textSoFar == "the cat")
}

@Test func extendingUntimedInterimReplacesItsCommittedPrefix() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello","is_final":true}"#), accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello world","is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.textSoFar == "hello world")

    var startOnly = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello","start":0,"duration":0.5,"is_final":true}"#),
        accumulating: &startOnly)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello world","start":0,"is_final":false}"#),
        accumulating: &startOnly)
    #expect(startOnly.textSoFar == "hello world")
}

@Test func grokAuthErrorBeforeAckClosesTheTransport() async throws {
    let transport = TestTransport(serverFrames: [
        grokFrame(#"{"type":"error","code":401,"message":"bad key"}"#)
    ])
    let client = GrokVoiceTranscribeClient(transport: transport)
    do {
        try await client.start(config: grokConfig())
        Issue.record("Expected an auth throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
    }
    #expect(transport.didClose)
}

@Test func grokCloseWithoutDoneThrows() async throws {
    let transport = TestTransport(serverFrames: [grokCreated])
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: grokConfig())
    do {
        for try await _ in client.finish() {}
        Issue.record("Expected a server-closed throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .serverClosed)
    }
}

@Test func grokAudioBeforeStartThrowsInvalidState() async {
    let client = GrokVoiceTranscribeClient(transport: TestTransport())
    await #expect(
        throws: TranscriptionError(kind: .invalidState, message: "Audio sent outside an active session.")
    ) {
        try await client.sendAudio(PCMFrame(samples: [1, -1]))
    }
}

@Test func grokTransportErrorsMapUnauthorizedToAuth() {
    let error = NSError(
        domain: NSURLErrorDomain, code: 401,
        userInfo: [NSLocalizedDescriptionKey: "unauthorized 401"])
    let mapped = GrokVoiceTranscribeClient.classifyTransportError(error)
    #expect(mapped.isAuthFailure)
}

@Test func grokMidSessionWriteFailuresSurfaceTheDisconnectCopy() async throws {
    // The same socket drop classifies on the read path; a write-side drop
    // must not surface a raw NSError instead of that friendly copy.
    let writeErrors: [Error] = [
        NSError(domain: NSPOSIXErrorDomain, code: 54),
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
    ]
    for writeError in writeErrors {
        let transport = TestTransport(serverFrames: [grokCreated], writeError: writeError)
        let client = GrokVoiceTranscribeClient(transport: transport)
        try await client.start(config: grokConfig())
        do {
            try await client.sendAudio(PCMFrame(samples: [1, -1]))
            Issue.record("Expected a classified write failure")
        } catch let failure as TranscriptionError {
            #expect(failure.kind == .serverClosed)
            #expect(failure.message == "The speech service disconnected before finishing. Try again.")
        }
    }
}

@Test func grokTransportErrorsMapInvalidKeyToAuth() {
    let error = NSError(
        domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
        userInfo: [NSLocalizedDescriptionKey: "invalid-key"])
    let mapped = GrokVoiceTranscribeClient.classifyTransportError(error)
    #expect(mapped.isAuthFailure)
    #expect(mapped.message == "Grok rejected the API key. Check Settings → Providers.")
    let specific = TranscriptionError.auth("The key is scoped to a different project.")
    #expect(GrokVoiceTranscribeClient.classifyTransportError(specific) == specific)
}

@Test func grokRefusesKeysThatWouldBreakTheUpgradeHeader() async throws {
    for key in ["good\r\nX-Forged: 1", "with\nnewline", "nul\u{0}byte"] {
        let config = grokConfig(values: ["apiKey": key])
        #expect(GrokProvider().connection(for: config) == nil)
        let transport = TestTransport(serverFrames: [grokCreated])
        let client = GrokVoiceTranscribeClient(transport: transport)
        do {
            try await client.start(config: config)
            Issue.record("Expected an invalid-key throw for \(key.debugDescription)")
        } catch let failure as TranscriptionError {
            #expect(failure.isAuthFailure)
            #expect(failure.message == TranscriptionError.invalidAPIKeyCharactersMessage)
        }
        #expect(!transport.didConnect)
    }
}

@Test func grokCleanKeyStillBuildsTheAuthorizationHeader() throws {
    let connection = try #require(
        GrokProvider().connection(for: grokConfig(values: ["apiKey": "xai-clean-key"])))
    #expect(connection.headers["Authorization"] == "Bearer xai-clean-key")
}

@Test func metaKeyRidesTheJSONBodyWithoutTheHeaderGuard() throws {
    // Meta's key is JSON-encoded in the handshake body, where control
    // characters cannot split headers; the connection must not be refused.
    let config = ProviderConfiguration(
        provider: .meta, values: ["apiKey": "meta\r\nkey", "audioEncoding": "PCM_16KHZ"])
    #expect(MetaProvider().connection(for: config) != nil)
    #expect(try MetaSessionConfig(from: config).apiKey == "meta\r\nkey")
}

@Test func grokEndpointCarriesQueryConfig() {
    let bare = GrokVoiceTranscribeClient.endpointURL()
    #expect(bare.host == "api.x.ai")
    #expect(bare.path == "/v1/stt")
    #expect(bare.query?.contains("model=grok-voice-transcribe-2.0") == true)
    #expect(bare.query?.contains("sample_rate=16000") == true)
    #expect(bare.query?.contains("encoding=pcm") == true)
    #expect(bare.query?.contains("interim_results=true") == true)
    #expect(bare.query?.contains("language=") != true)

    let rich = GrokVoiceTranscribeClient.endpointURL(
        from: grokConfig(values: [
            "apiKey": "k",
            "languageBias": "en",
            "keywords": "Acme,Grok",
        ]))
    #expect(rich.query?.contains("model=grok-voice-transcribe-2.0") == true)
    #expect(rich.query?.contains("language=en") == true)
    #expect(rich.query?.contains("keyterm=Acme") == true)
    #expect(rich.query?.contains("keyterm=Grok") == true)

    let fallback = GrokVoiceTranscribeClient.endpointURL(
        from: grokConfig(values: ["apiKey": "k", "model": "grok-voice-transcribe-1.0"]))
    #expect(fallback.query?.contains("model=grok-voice-transcribe-1.0") == true)
}

@Test func grokKeytermPlusSignsSurviveQueryDecoding() {
    // xAI decodes "+" in the query as a space (its docs show
    // keyterm=Understand+The+Universe), so "C++" must go out as C%2B%2B.
    let url = GrokVoiceTranscribeClient.endpointURL(keyterms: ["C++", "Notepad++", "a b"])
    let query = url.query(percentEncoded: true) ?? ""
    #expect(query.contains("keyterm=C%2B%2B"))
    #expect(query.contains("keyterm=Notepad%2B%2B"))
    #expect(query.contains("keyterm=a%20b"))
    #expect(!query.contains("+"))
    let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(decoded.filter { $0.name == "keyterm" }.map(\.value) == ["C++", "Notepad++", "a b"])
}

@Test func wordlessScriptCumulativeResendReplacesInsteadOfDuplicating() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"你好","is_final":true}"#), accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"你好世界","is_final":false}"#), accumulating: &transcript)
    #expect(transcript.textSoFar == "你好世界")
}

@Test func timedShorterInterimCannotDeleteALockedSegment() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello world","start":0,"duration":2,"is_final":true}"#),
        accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello","start":0,"duration":1,"is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.textSoFar == "hello world")
    // A completion marker with no text must still fall back to it.
    #expect(transcript.complete(with: "") == "hello world")
}

@Test func timedExtendingInterimStillReplacesItsCommittedPrefix() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello","start":0,"duration":1,"is_final":true}"#),
        accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello world","start":0,"duration":2,"is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.textSoFar == "hello world")
}

@Test(arguments: ["yes", "你好", "네"])
func grokRepeatedUntimedUtterancesSurviveAnEmptyDone(text: String) async throws {
    let utterance = grokFrame(
        #"{"type":"transcript.partial","text":"\#(text)","is_final":true,"speech_final":true}"#)
    let transport = TestTransport(serverFrames: [
        grokCreated, utterance, utterance, grokFrame(#"{"type":"transcript.done","text":""}"#),
    ])
    let client = GrokVoiceTranscribeClient(transport: transport)
    try await client.start(config: grokConfig())
    var events: [TranscriptionEvent] = []
    for try await event in client.finish() { events.append(event) }
    #expect(events == [.partial(text), .partial("\(text) \(text)"), .final("\(text) \(text)")])
}

@Test func aNewUntimedInterimCannotSupersedeThePreviousUtterance() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"yes","start":0,"duration":1,"speech_final":true}"#),
        accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"yes please","is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.textSoFar == "yes yes please")
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"yes please","speech_final":true}"#),
        accumulating: &transcript)
    #expect(transcript.complete(with: "") == "yes yes please")
}

@Test func timedRestatementsStillUseTheirAudioSpanAcrossBoundaries() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello","start":0,"duration":1,"speech_final":true}"#),
        accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"hello there","start":0,"duration":2,"speech_final":true}"#),
        accumulating: &transcript)
    #expect(transcript.complete(with: "") == "hello there")
}

@Test func aCJKSuffixCannotEraseALockedLatinWord() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"No","is_final":true}"#), accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"Nobody knows 中文","is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.textSoFar == "No Nobody knows 中文")
    #expect(
        GrokWireProtocol.decodeServerEvent(
            grokFrame(#"{"type":"transcript.done","text":""}"#), accumulating: &transcript)
            == .final("No Nobody knows 中文"))
}

@Test func aMixedScriptPrefixStillChecksItsFinalLatinWordBoundary() {
    var transcript = GrokTranscriptAccumulator()
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"中文 No","is_final":true}"#), accumulating: &transcript)
    _ = GrokWireProtocol.decodeServerEvent(
        grokFrame(#"{"type":"transcript.partial","text":"中文 Nobody knows","is_final":false}"#),
        accumulating: &transcript)
    #expect(transcript.complete(with: "") == "中文 No 中文 Nobody knows")
}
