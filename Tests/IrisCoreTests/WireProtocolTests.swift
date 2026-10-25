import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func json(_ text: String) -> Data { Data(text.utf8) }

private func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TranscriptionError(kind: .decoding, message: "Expected a JSON object.")
    }
    return value
}

private func session(
    mode: MetaTranscriptionMode = .pushToTalk,
    encoding: MetaAudioEncoding = .pcm16k,
    sessionId: String? = nil
) -> MetaSessionConfig {
    MetaSessionConfig(apiKey: "test-key", audioEncoding: encoding, mode: mode, sessionId: sessionId)
}

// MARK: - Handshake encoding

@Test func handshakeCarriesAuthEncodingAndDefaults() throws {
    let data = MetaWireProtocol.encodeHandshake(config: session())
    let payload = try object(data)
    let auth = payload["authorization"] as? [String: String]
    #expect(auth?["accessToken"] == "Bearer test-key")
    #expect(payload["audioEncoding"] as? String == "PCM_16KHZ")
    #expect(payload["mode"] as? String == "PUSH_TO_TALK")
    #expect(payload["partialMode"] as? String == "CUMULATIVE")
    #expect(payload["model"] as? String == "muse-voice-transcribe-1.0")
    #expect(payload["sessionId"] == nil)
    #expect(payload["languageBias"] == nil)
    #expect(payload["keywords"] == nil)
}

@Test func handshakeSendsFullLanguageNamesAndKeywords() throws {
    var config = session()
    config.languageBias = ["English"]
    config.keywords = ["Acme", "eSIM"]
    let payload = try object(MetaWireProtocol.encodeHandshake(config: config))
    #expect((payload["languageBias"] as? [Any])?.compactMap { $0 as? String } == ["English"])
    #expect((payload["keywords"] as? [Any])?.compactMap { $0 as? String } == ["Acme", "eSIM"])
}

@Test func languageBiasMapsCodesAndTreatsEmptyAsAuto() {
    #expect(MetaLanguageBias.names.count == 25)
    #expect(MetaLanguageBias.normalize("en") == "English")
    #expect(MetaLanguageBias.normalize("zh-cn") == "Mandarin Chinese")
    #expect(MetaLanguageBias.normalize("Auto") == MetaLanguageBias.auto)
    #expect(MetaLanguageBias.normalize("") == MetaLanguageBias.auto)
    #expect(MetaLanguageBias.selection(from: "en,fr") == "English")
    #expect(MetaLanguageBias.wireValues(from: "en, fr") == ["English", "French"])
    #expect(MetaLanguageBias.wireValues(from: "") == [])
}

@Test func handshakeIncludesSessionIdWhenSet() throws {
    let data = MetaWireProtocol.encodeHandshake(config: session(sessionId: "abc-123"))
    #expect(try object(data)["sessionId"] as? String == "abc-123")
}

@Test func handshakeMaps24kEncoding() throws {
    let data = MetaWireProtocol.encodeHandshake(config: session(encoding: .pcm24k))
    #expect(try object(data)["audioEncoding"] as? String == "PCM_24KHZ")
}

@Test func sessionConfigRejectsMissingEncodingAndKey() {
    #expect(throws: (any Error).self) {
        try MetaSessionConfig(from: ProviderConfiguration(provider: .meta, values: ["apiKey": "k"]))
    }
    #expect(throws: (any Error).self) {
        try MetaSessionConfig(
            from: ProviderConfiguration(provider: .meta, values: ["audioEncoding": "PCM_16KHZ"]))
    }
    #expect(throws: (any Error).self) {
        try MetaSessionConfig(
            from: ProviderConfiguration(provider: .meta, values: ["apiKey": "k", "audioEncoding": "MP3"]))
    }
}

@Test func metaSessionRequiresAnAPIKeyWithActionableCopy() {
    do {
        _ = try MetaSessionConfig(
            from: ProviderConfiguration(provider: .meta, values: ["audioEncoding": "PCM_16KHZ"]))
        Issue.record("Expected a missing-key throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
        #expect(failure.message == "Missing Meta API key. Add an API key in Settings → Providers.")
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@Test func handshakeKeywordsAreCappedToAPILimits() throws {
    // Grok caps custom words to 100 terms x 50 characters; Meta's handshake
    // must not ship an oversized keyword list the same field allows there.
    let long = String(repeating: "k", count: 80)
    let many = (0..<120).map { "kw\($0)" }
    let values = ([long] + many).joined(separator: ",")
    let config = try MetaSessionConfig(
        from: ProviderConfiguration(
            provider: .meta,
            values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "keywords": values]))
    #expect(config.keywords.count == 100)
    #expect(config.keywords.first == String(repeating: "k", count: 50))
    let payload = try object(MetaWireProtocol.encodeHandshake(config: config))
    #expect((payload["keywords"] as? [Any])?.compactMap { $0 as? String } == config.keywords)
}

@Test func encodingMapsKnownSampleRates() {
    #expect(MetaAudioEncoding(sampleRate: 16000) == .pcm16k)
    #expect(MetaAudioEncoding(sampleRate: 24000) == .pcm24k)
    #expect(MetaAudioEncoding(sampleRate: 8000) == nil)
}

// MARK: - ACK

@Test func bareSessionIdIsAck() {
    #expect(MetaWireProtocol.isHandshakeAck(json(#"{"sessionId":"s-1"}"#)))
    #expect(!MetaWireProtocol.isHandshakeAck(json(#"{"type":"transcript","transcript":"hi"}"#)))
    #expect(!MetaWireProtocol.isHandshakeAck(json(#"{"sessionId":"s-1","type":"ack"}"#)))
}

// MARK: - Transcript decoding

@Test func pushToTalkFinalizesOnFinalFlag() {
    let event = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"transcript","transcript":"hello world","final":true}"#))
    #expect(event == .final("hello world"))
}

@Test func pushToTalkNonFinalStaysPartial() {
    let event = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"transcript","transcript":"hel","final":false}"#))
    #expect(event == .partial("hel"))
    let missing = MetaWireProtocol.decodeServerEvent(json(#"{"type":"transcript","transcript":"hel"}"#))
    #expect(missing == .partial("hel"))
}

@Test func endpointingSpeechCompleteIsATurnNotASessionFinal() {
    let turn = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"speechComplete","turnId":"t-1","transcript":"take the trash out"}"#),
        mode: .endpointing)
    #expect(turn == .speechComplete(turnId: "t-1", transcript: "take the trash out"))
    let diarized = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"speechComplete","turnId":"t-2","transcript":"hi"}"#),
        mode: .diarization)
    #expect(diarized == .speechComplete(turnId: "t-2", transcript: "hi"))
    #expect(turn?.isFinal == false)
}

@Test func endpointingTranscriptsStayPartial() {
    let event = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"transcript","transcript":"take the","final":true}"#),
        mode: .endpointing)
    #expect(event == .partial("take the"))
}

@Test func pushToTalkKeepsSpeechCompleteAsBoundary() {
    let event = MetaWireProtocol.decodeServerEvent(json(#"{"type":"speechComplete","turnId":"t-9"}"#))
    #expect(event == .speechComplete(turnId: "t-9", transcript: ""))
}

@Test func speechStartedDecodes() {
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"speechStarted"}"#)) == .speechStarted)
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"speechStart"}"#)) == .speechStarted)
}

@Test func speechCompleteAcceptsNumericTurnId() {
    let event = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"speechComplete","turnId":1,"transcript":"hello"}"#), mode: .endpointing)
    #expect(event == .speechComplete(turnId: "1", transcript: "hello"))
}

// MARK: - Edge cases

@Test func unknownAndMalformedEventsAreIgnored() {
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"heartbeat"}"#)) == nil)
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"sessionId":"s-1"}"#)) == nil)
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"transcript"}"#)) == nil)
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"transcript","transcript":""}"#)) == nil)
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"speechComplete"}"#)) == nil)
    #expect(MetaWireProtocol.decodeServerEvent(json("not json")) == nil)
    #expect(MetaWireProtocol.decodeServerEvent(Data()) == nil)
}

@Test func overlappingTurnsDecodeIndependently() {
    let first = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"transcript","transcript":"first","final":true,"turnId":"a"}"#))
    let second = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"transcript","transcript":"second","final":true,"turnId":"b"}"#))
    #expect(first == .final("first"))
    #expect(second == .final("second"))
}

@Test func errorsClassifyAuth() {
    let coded = MetaWireProtocol.decodeServerEvent(json(#"{"type":"error","code":401,"message":"bad key"}"#))
    #expect(coded == .error(TranscriptionError(kind: .authentication, message: "bad key")))
    let worded = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"error","message":"Invalid API key"}"#))
    if case .error(let failure) = worded {
        #expect(failure.isAuthFailure)
    } else {
        Issue.record("Expected an error event")
    }
    let limited = MetaWireProtocol.decodeServerEvent(
        json(#"{"type":"error","code":429,"message":"slow down"}"#))
    #expect(limited == .error(TranscriptionError(kind: .rateLimited, message: "slow down")))
}

@Test func emptyPushToTalkFinalIsACompletion() {
    #expect(
        MetaWireProtocol.decodeServerEvent(json(#"{"type":"transcript","transcript":"","final":true}"#))
            == .final(""))
    // Empty partials are still dropped.
    #expect(MetaWireProtocol.decodeServerEvent(json(#"{"type":"transcript","transcript":"","final":false}"#)) == nil)
}
