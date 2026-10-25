import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func wireJSON(_ text: String) -> Data { Data(text.utf8) }

@Test func encodingRoundTripsSampleRates() {
    #expect(MetaAudioEncoding.pcm16k.sampleRate == 16000)
    #expect(MetaAudioEncoding.pcm24k.sampleRate == 24000)
}

@Test func completionPolicyFollowsMode() {
    #expect(
        MetaSessionConfig(apiKey: "k", audioEncoding: .pcm16k, mode: .pushToTalk).completionPolicy
            == .finalEvent)
    #expect(
        MetaSessionConfig(apiKey: "k", audioEncoding: .pcm16k, mode: .endpointing).completionPolicy
            == .turnComplete)
    #expect(
        MetaSessionConfig(apiKey: "k", audioEncoding: .pcm16k, mode: .diarization).completionPolicy
            == .turnComplete)
    #expect(
        MetaProvider().completionPolicy(for: ProviderConfiguration(provider: .meta, values: [:]))
            == .finalEvent)
    #expect(
        MetaProvider().completionPolicy(
            for: ProviderConfiguration(provider: .meta, values: ["mode": "ENDPOINTING"]))
            == .turnComplete)
    #expect(
        MetaProvider().completionPolicy(
            for: ProviderConfiguration(provider: .meta, values: ["mode": "DIARIZATION"]))
            == .turnComplete)
    #expect(
        MetaProvider().completionPolicy(
            for: ProviderConfiguration(provider: .meta, values: ["mode": "NOPE"]))
            == .finalEvent)
}

@Test func endpointingTurnBoundaryWithoutTextStaysABoundary() {
    #expect(
        MetaWireProtocol.decodeServerEvent(
            wireJSON(#"{"type":"speechComplete","turnId":"t-3"}"#), mode: .endpointing)
            == .speechComplete(turnId: "t-3", transcript: ""))
}

@Test func endpointingSpeechCompleteWithoutUsablePayloadIsIgnored() {
    #expect(
        MetaWireProtocol.decodeServerEvent(wireJSON(#"{"type":"speechComplete"}"#), mode: .endpointing)
            == nil)
    #expect(
        MetaWireProtocol.decodeServerEvent(
            wireJSON(#"{"type":"speechComplete","transcript":""}"#), mode: .endpointing) == nil)
}

@Test func errorsClassifyRateQuotaAndStreamLimits() {
    let rate = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Rate limit exceeded"}"#))
    #expect(rate == .error(TranscriptionError(kind: .rateLimited, message: "Rate limit exceeded")))
    let quota = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Quota exhausted"}"#))
    #expect(quota == .error(TranscriptionError(kind: .rateLimited, message: "Quota exhausted")))
    let streamLimit = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Stream limit reached"}"#))
    #expect(
        streamLimit == .error(TranscriptionError(kind: .streamLimit, message: "Stream limit reached")))
    let tooMany = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Too many sessions"}"#))
    #expect(tooMany == .error(TranscriptionError(kind: .streamLimit, message: "Too many sessions")))
    let unknown = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"kaboom"}"#))
    #expect(unknown == .error(TranscriptionError(kind: .unknown, message: "kaboom")))
    let coded = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","code":500,"message":"kaboom"}"#))
    #expect(coded == .error(TranscriptionError(kind: .unknown, message: "kaboom")))
    let status = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","status":403,"message":"forbidden"}"#))
    #expect(status == .error(TranscriptionError(kind: .authentication, message: "forbidden")))
    let bare = MetaWireProtocol.decodeServerEvent(wireJSON(#"{"type":"error"}"#))
    #expect(bare == .error(TranscriptionError(kind: .unknown, message: "Transcription failed.")))
    let unauthorized = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"unauthorized"}"#))
    if case .error(let failure) = unauthorized {
        #expect(failure.isAuthFailure)
    } else {
        Issue.record("Expected an error event")
    }
}

@Test func errorsReadDocumentedErrorCodeFields() {
    // Meta's documented ErrorEvent shape carries errorCode/errorType
    // strings; classification must not depend on message wording alone.
    let invalidKey = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Request rejected","errorCode":"invalid_api_key"}"#))
    #expect(
        invalidKey == .error(TranscriptionError(kind: .authentication, message: "Request rejected")))
    let authType = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Request rejected","errorType":"authentication_error"}"#))
    if case .error(let failure) = authType {
        #expect(failure.isAuthFailure)
    } else {
        Issue.record("Expected an error event")
    }
    let rateCoded = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Slow down","errorCode":"rate_limit_exceeded"}"#))
    #expect(rateCoded == .error(TranscriptionError(kind: .rateLimited, message: "Slow down")))
    for code in ["invalid_token", "invalid-key"] {
        let event = MetaWireProtocol.decodeServerEvent(
            wireJSON("{\"type\":\"error\",\"message\":\"Request rejected\",\"errorCode\":\"\(code)\"}"))
        #expect(event == .error(TranscriptionError(kind: .authentication, message: "Request rejected")))
    }
    for code in ["rate-limit", "too many requests"] {
        let event = MetaWireProtocol.decodeServerEvent(
            wireJSON("{\"type\":\"error\",\"message\":\"Slow down\",\"errorCode\":\"\(code)\"}"))
        #expect(event == .error(TranscriptionError(kind: .rateLimited, message: "Slow down")))
    }
    let streamCoded = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Busy","errorCode":"stream_limit"}"#))
    #expect(streamCoded == .error(TranscriptionError(kind: .streamLimit, message: "Busy")))
}

@Test func grokErrorsClassifyStreamLimitsAndValidationFailures() {
    // Grok mirrors Meta: stream/session limits map to .streamLimit, and a
    // validation failure never reads as auth or rate from bare words.
    let streamLimit = GrokWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Stream limit reached"}"#))
    #expect(
        streamLimit == .error(TranscriptionError(kind: .streamLimit, message: "Stream limit reached")))
    let tooMany = GrokWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Too many sessions"}"#))
    #expect(tooMany == .error(TranscriptionError(kind: .streamLimit, message: "Too many sessions")))
    let invalid = GrokWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"invalid_request"}"#))
    #expect(invalid == .error(TranscriptionError(kind: .unknown, message: "invalid_request")))
    let rate = GrokWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","message":"Rate limit exceeded"}"#))
    #expect(rate == .error(TranscriptionError(kind: .rateLimited, message: "Rate limit exceeded")))
}

@Test func unrecognizedStoredModeIsRejected() {
    // A mode the server does not know would silently transcribe in the
    // wrong mode and change the completion policy; reject it loudly.
    let config = ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "mode": "TELEPATHY"])
    do {
        _ = try MetaSessionConfig(from: config)
        Issue.record("Expected a decoding throw")
    } catch let failure as TranscriptionError {
        #expect(failure.kind == .decoding)
    } catch {
        Issue.record("Unexpected error type")
    }
}

@Test func sessionConfigMapsDescriptorValues() throws {
    let config = ProviderConfiguration(
        provider: .meta,
        values: [
            "apiKey": "k", "audioEncoding": "PCM_24KHZ", "mode": "ENDPOINTING",
            "model": "custom-model", "languageBias": "en,fr", "keywords": "iris, dictation",
            "sessionId": "s-9", "partialMode": "CUMULATIVE",
        ])
    let session = try MetaSessionConfig(from: config)
    #expect(session.audioEncoding == .pcm24k)
    #expect(session.mode == .endpointing)
    #expect(session.partialMode == .cumulative)
    #expect(session.model == "custom-model")
    #expect(session.languageBias == ["English", "French"])
    #expect(session.keywords == ["iris", "dictation"])
    #expect(session.sessionId == "s-9")
}

@Test func sessionConfigDefaultsBiasModeAndModel() throws {
    let session = try MetaSessionConfig(
        from: ProviderConfiguration(
            provider: .meta, values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ"]))
    #expect(session.languageBias == [])
    #expect(session.mode == .pushToTalk)
    #expect(session.model == MetaSessionConfig.defaultModel)
    #expect(session.keywords == [])
    #expect(session.sessionId == nil)
    let blank = try MetaSessionConfig(
        from: ProviderConfiguration(
            provider: .meta, values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ", "model": "  "]))
    #expect(blank.model == MetaSessionConfig.defaultModel)
}

@Test func endStreamMarkerIsNotATranscriptEvent() {
    let marker = MetaWireProtocol.encodeEndStream()
    #expect(MetaWireProtocol.decodeServerEvent(marker) == nil)
    #expect(String(data: marker, encoding: .utf8) == #"{"type":"endStream"}"#)
}

@Test func authAndRateMessagesStayClassified() {
    let token = MetaWireProtocol.decodeServerEvent(wireJSON(#"{"type":"error","message":"Invalid access token"}"#))
    #expect(token == .error(TranscriptionError(kind: .authentication, message: "Invalid access token")))
    let rate = MetaWireProtocol.decodeServerEvent(wireJSON(#"{"type":"error","message":"Rate exceeded"}"#))
    #expect(rate == .error(TranscriptionError(kind: .rateLimited, message: "Rate exceeded")))
    // An empty errorCode must not mask a usable errorType.
    let typed = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","errorCode":"","errorType":"rate_limit_error","message":"Slow down"}"#))
    #expect(typed == .error(TranscriptionError(kind: .rateLimited, message: "Slow down")))
}

@Test func validationErrorsAreNotReportedAsKeyOrRateProblems() {
    let typed = MetaWireProtocol.decodeServerEvent(
        wireJSON(#"{"type":"error","errorType":"invalid_request_error","message":"Invalid audio encoding"}"#))
    #expect(typed == .error(TranscriptionError(kind: .unknown, message: "Invalid audio encoding")))
    // Message heuristics: "invalid" is not a key problem, "sample rate" is not a rate limit.
    let bare = MetaWireProtocol.decodeServerEvent(wireJSON(#"{"type":"error","message":"Invalid sample rate"}"#))
    #expect(bare == .error(TranscriptionError(kind: .unknown, message: "Invalid sample rate")))
    #expect(TranscriptionError.mentionsRateLimit("rate limit exceeded"))
    #expect(!TranscriptionError.mentionsRateLimit("unsupported sample rate"))
}

@Test func authPhrasesAgreeAcrossWireAndTransportDoors() {
    // One sentence must classify the same regardless of which door saw it.
    let authPhrases = [
        "unauthorized", "not authenticated", "invalid-key", "invalid api key", "Invalid API key",
        "invalid token", "Invalid access token", "invalid credential", "authentication required",
        "api key expired",
    ]
    for phrase in authPhrases {
        let transport = TranscriptionError.classifiedTransportError(in: phrase)
        let wire = TranscriptionError.classifiedServerPhrase(in: phrase.lowercased())
        #expect(
            transport?.isAuthFailure == true, "transport door missed \(phrase)")
        #expect(wire == .authentication, "wire door missed \(phrase)")
    }
    // Phrases that are not auth verdicts on one door stay non-auth on the other.
    let plainPhrases = ["Room 401 is not available", "invalid request", "Invalid sample rate", "kaboom"]
    for phrase in plainPhrases {
        let transport = TranscriptionError.classifiedTransportError(in: phrase)
        let wire = TranscriptionError.classifiedServerPhrase(in: phrase.lowercased())
        #expect(transport?.isAuthFailure != true)
        #expect(wire != .authentication)
    }
}
