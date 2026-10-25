import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func grokJSON(_ text: String) -> Data { Data(text.utf8) }

@Test func grokAudioDoneIsAControlObject() {
    #expect(String(data: GrokWireProtocol.encodeAudioDone(), encoding: .utf8) == #"{"type":"audio.done"}"#)
}

@Test func grokReadyAckIsTranscriptCreated() {
    #expect(GrokWireProtocol.isReadyAck(grokJSON(#"{"type":"transcript.created"}"#)))
    #expect(!GrokWireProtocol.isReadyAck(grokJSON(#"{"type":"transcript.partial","text":"hi"}"#)))
    #expect(!GrokWireProtocol.isReadyAck(grokJSON(#"{"sessionId":"s-1"}"#)))
}

@Test func grokEventAliasReadyAckSatisfiesTheGate() {
    // The decoder accepts `event` as an alias for `type`; the ready gate
    // must accept the same shape or an alias frame stalls to the ack timeout.
    let alias = grokJSON(#"{"event":"transcript.created"}"#)
    #expect(GrokWireProtocol.isReadyAck(alias))
    #expect(GrokWireProtocol.decodeServerEvent(alias) == nil)
    let aliasPartial = grokJSON(#"{"event":"transcript.partial","text":"hi"}"#)
    #expect(GrokWireProtocol.decodeServerEvent(aliasPartial) == .partial("hi"))
}

@Test func grokPartialsReplaceAndDoneCompletes() {
    #expect(
        GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"transcript.partial","text":"hel","is_final":false}"#))
            == .partial("hel"))
    #expect(
        GrokWireProtocol.decodeServerEvent(
            grokJSON(#"{"type":"transcript.partial","text":"hello","is_final":true,"speech_final":true}"#))
            == .partial("hello"))
    #expect(
        GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"transcript.done","text":"hello","duration":1.2}"#))
            == .final("hello"))
    #expect(
        GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"transcript.done","transcript":"hello"}"#))
            == .final("hello"))
}

@Test func grokSpeechFinalDoesNotCompletePushToTalk() {
    let event = GrokWireProtocol.decodeServerEvent(
        grokJSON(#"{"type":"transcript.partial","text":"pause","is_final":true,"speech_final":true}"#))
    #expect(event == .partial("pause"))
    #expect(event?.isFinal == false)
}

@Test func grokDoneWithEmptyTextStillCompletes() {
    #expect(
        GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"transcript.done","text":"","duration":0.4}"#))
            == .final(""))
}

@Test func grokAuthErrorClassifies() {
    let event = GrokWireProtocol.decodeServerEvent(
        grokJSON(#"{"type":"error","code":401,"message":"unauthorized"}"#))
    #expect(event == .error(TranscriptionError(kind: .authentication, message: "unauthorized")))
}

@Test func grokUnknownFramesAreIgnored() {
    #expect(GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"transcript.created"}"#)) == nil)
    #expect(GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"heartbeat"}"#)) == nil)
    #expect(GrokWireProtocol.decodeServerEvent(grokJSON(#"{"type":"transcript.partial"}"#)) == nil)
}

@Test func grokLanguageNormalizesCodesAndNames() {
    #expect(GrokLanguage.normalize("") == GrokLanguage.auto)
    #expect(GrokLanguage.normalize("en") == "en")
    #expect(GrokLanguage.normalize("English") == "en")
    #expect(GrokLanguage.selection(from: "EN") == "en")
    #expect(GrokLanguage.selection(from: "nope") == GrokLanguage.auto)
    #expect(GrokLanguage.label(for: "ja") == "Japanese")
}

@Test func grokSessionRequiresAnAPIKey() {
    do {
        _ = try GrokSessionConfig(from: ProviderConfiguration(provider: .grok, values: [:]))
        Issue.record("Expected a missing-key throw")
    } catch let failure as TranscriptionError {
        #expect(failure.isAuthFailure)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@Test func grokSessionUnknownLanguageBecomesAutoLikeTheWire() throws {
    let session = try GrokSessionConfig(
        from: ProviderConfiguration(
            provider: .grok, values: ["apiKey": "k", "languageBias": "klingon"]))
    #expect(session.language == GrokLanguage.auto)
}

@Test func grokSessionMapsLanguageAndKeyterms() throws {
    let session = try GrokSessionConfig(
        from: ProviderConfiguration(
            provider: .grok,
            values: [
                "apiKey": "k",
                "languageBias": "English",
                "keywords": "Acme, eSIM, ",
            ]))
    #expect(session.language == "en")
    #expect(session.keyterms == ["Acme", "eSIM"])
    #expect(session.completionPolicy == .finalEvent)
}

@Test func grokSessionDefaultsToTranscribeTwoAndHonorsStoredModel() throws {
    let implicit = try GrokSessionConfig(
        from: ProviderConfiguration(provider: .grok, values: ["apiKey": "k"]))
    #expect(implicit.model == "grok-voice-transcribe-2.0")
    let blank = try GrokSessionConfig(
        from: ProviderConfiguration(provider: .grok, values: ["apiKey": "k", "model": "  "]))
    #expect(blank.model == GrokSessionConfig.defaultModel)
    let explicit = try GrokSessionConfig(
        from: ProviderConfiguration(
            provider: .grok, values: ["apiKey": "k", "model": "grok-voice-transcribe-1.0"]))
    #expect(explicit.model == "grok-voice-transcribe-1.0")
}

@Test func grokKeytermsHonorAPILimits() {
    let long = String(repeating: "a", count: 80)
    let many = (0..<120).map { "t\($0)" }
    let capped = GrokSessionConfig.sanitizedKeyterms([long] + many)
    #expect(capped.first == String(repeating: "a", count: 50))
    #expect(capped.count == 100)
}
