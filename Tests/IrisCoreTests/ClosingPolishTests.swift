import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func preparedTextNeverDuplicatesTrailingSeparators() {
    #expect(DictationTextProcessor.prepare("hello ", trailingSpace: true) == "hello ")
    #expect(DictationTextProcessor.prepare("hello\n", trailingSpace: true) == "hello\n")
    #expect(DictationTextProcessor.prepare("hello\n", trailingSpace: true, trailingNewline: true) == "hello\n")
}

@Test func preparedTextWithBothTogglesAppendsSpaceThenNewline() {
    #expect(
        DictationTextProcessor.prepare("hello", trailingSpace: true, trailingNewline: true) == "hello \n")
}

@Test func chunkingShortTextStaysSingleChunk() {
    let chunks = DictationTextProcessor.chunk("hello world")
    #expect(chunks == ["hello world"])
}

@Test func chunkingWithNonPositiveLimitReturnsWholeText() {
    #expect(DictationTextProcessor.chunk("hello", maxUTF16: 0) == ["hello"])
    #expect(DictationTextProcessor.chunk("hello", maxUTF16: -4) == ["hello"])
}

@Test func chunkingEmptyTextReturnsSingleChunk() {
    #expect(DictationTextProcessor.chunk("") == [""])
}

@Test func silenceFrameDurationMatchesStreamingCadence() {
    #expect(PCMFrame.silence(sampleCount: 1600, sampleRate: 16000).durationSeconds == 0.1)
    #expect(PCMFrame.silence(sampleCount: 2400, sampleRate: 24000).durationSeconds == 0.1)
}

@Test func authFailuresAreDistinguishedFromRetryableOnes() {
    #expect(TranscriptionError.auth("bad key").isAuthFailure)
    #expect(!TranscriptionError(kind: .network, message: "dropped").isAuthFailure)
    #expect(!TranscriptionError(kind: .rateLimited, message: "slow down").isAuthFailure)
    #expect(!TranscriptionError(kind: .timeout, message: "timed out").isAuthFailure)
}

@Test func errorDescriptionMatchesMessage() {
    let failure = TranscriptionError(kind: .network, message: "dropped")
    #expect(failure.description == "dropped")
}

@Test func unknownProviderNameHasNoDescriptor() {
    let registry = testProviderRegistry()
    #expect(registry.descriptor(forName: "no-such-provider") == nil)
    #expect(
        registry.makeClient(
            named: "no-such-provider", config: ProviderConfiguration(provider: .mock, values: [:]),
            transport: TestTransport()) == nil)
}

@Test func failedSessionRejectsLateCompletion() {
    var session = TranscriptionSession()
    session.begin()
    session.fail(TranscriptionError(kind: .network, message: "dropped"))
    #expect(session.phase == .idle)
    #expect(session.complete(final: "late") == nil)
}

@Test func sessionIgnoresPartialsWhenIdle() {
    var session = TranscriptionSession()
    session.accumulate(partial: "stray")
    #expect(session.partialText.isEmpty)
}
