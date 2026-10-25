import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func endpointingJoinsCJKTurnsWithoutASCIIspaces() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "1", text: "你好")
    session.recordTurn(id: "2", text: "世界")
    #expect(session.finishTurns() == "你好世界")
}

@Test func endpointingUsesNumericTurnOrderWhenCompletionArrivesOutOfOrder() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "2", text: "second")
    session.recordTurn(id: "1", text: "first")
    #expect(session.finishTurns() == "first second")
}

@Test func outOfOrderTurnsAndCumulativeTrailingPartialComposeWithoutDuplication() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "2", text: "second")
    session.recordTurn(id: "1", text: "first")
    session.accumulate(partial: "first again")
    #expect(session.finishTurns() == "first again second")
}

@Test func grokJoinsCJKSegmentsWithoutASCIIspaces() {
    var accumulator = GrokTranscriptAccumulator()
    _ = accumulator.append(text: "你好", start: nil, duration: nil, isFinal: true, speechFinal: false)
    _ = accumulator.append(text: "世界", start: nil, duration: nil, isFinal: true, speechFinal: false)
    #expect(accumulator.textSoFar == "你好世界")
}

@Test func cjkPunctuationDoesNotCreateASCIIspaces() {
    #expect(DictationTextProcessor.joinTranscriptPieces(["你好。", "世界"]) == "你好。世界")
    #expect(DictationTextProcessor.joinTranscriptPieces(["你好", "，世界"]) == "你好，世界")
}

@Test func latinTurnsKeepTheirWordSeparator() {
    #expect(DictationTextProcessor.joinTranscriptPieces(["hello", "world"]) == "hello world")
}
