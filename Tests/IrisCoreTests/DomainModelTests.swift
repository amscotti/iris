import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func frameDurationAndSilence() {
    let frame = PCMFrame(samples: [Int16](repeating: 0, count: 1600))
    #expect(frame.durationSeconds == 0.1)
    #expect(frame.rms == 0)
    let silence = PCMFrame.silence(sampleCount: 1600)
    #expect(silence.samples.count == 1600)
    #expect(PCMFrame.samplesPerFrame(sampleRate: 16000) == 1600)
    #expect(PCMFrame.samplesPerFrame(sampleRate: 24000) == 2400)
}

@Test func frameBytesRoundTripLittleEndian() {
    let frame = PCMFrame(samples: [1, -2, 32767, -32768], sampleRate: 16000)
    let data = frame.asData()
    #expect(data.count == 8)
    #expect(data == Data([0x01, 0x00, 0xFE, 0xFF, 0xFF, 0x7F, 0x00, 0x80]))
}

@Test func loudFrameHasHigherRms() {
    let quiet = PCMFrame(samples: [100, -100, 100, -100])
    let loud = PCMFrame(samples: [10000, -10000, 10000, -10000])
    #expect(quiet.rms > 0)
    #expect(loud.rms > quiet.rms)
    #expect(loud.rms <= 1)
}

@Test func sessionGuardsSingleCompletion() {
    var session = TranscriptionSession()
    session.begin()
    session.accumulate(partial: "hel")
    #expect(session.partialText == "hel")
    #expect(session.complete(final: "hello") == "hello")
    #expect(session.complete(final: "hello again") == nil)
    #expect(session.phase == .idle)
}

@Test func sessionDedupesRepeatedCompletions() {
    var session = TranscriptionSession()
    session.begin()
    #expect(session.complete(final: "one", turnId: "t-1") == "one")
    #expect(session.complete(final: "two", turnId: "t-2") == nil)
    #expect(session.complete(final: "one", turnId: "t-1") == nil)
}

@Test func sessionJoinsEndpointingTurnsThenCompletesOnce() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "1", text: "hello")
    session.recordTurn(id: "1", text: "ignored duplicate")
    session.recordTurn(id: "2", text: "world")
    #expect(session.phase != .idle)
    #expect(session.finishTurns() == "hello world")
    #expect(session.finishTurns() == nil)
    #expect(session.phase == .idle)
}

@Test func sessionKeepsTheTrailingPartialAfterRecordedTurns() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "1", text: "hello")
    session.accumulate(partial: "world dom")
    // A trailing partial is the next utterance's speech: the final join
    // must append it after the recorded turns instead of dropping it.
    #expect(session.finishTurns() == "hello world dom")
    #expect(session.finishTurns() == nil)
    #expect(session.phase == .idle)
}

@Test func redeliveredTextlessIdTurnsJoinOnce() {
    var session = TranscriptionSession()
    session.begin()
    // Frames without a turn id cannot be deduped by id; a redelivered
    // boundary repeats the same piece and must not duplicate it.
    session.recordTurn(id: "", text: "hello world")
    session.recordTurn(id: "", text: "hello world")
    #expect(session.finishTurns() == "hello world")
}

@Test func cumulativeTrailingPartialReplacesTheRestatedTurn() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "1", text: "hello world")
    session.accumulate(partial: "hello world again")
    // A cumulative re-send extends the same speech: replace, don't join.
    #expect(session.finishTurns() == "hello world again")
}

@Test func staleShorterTrailingPartialIsDropped() {
    var session = TranscriptionSession()
    session.begin()
    session.recordTurn(id: "1", text: "hello world")
    session.accumulate(partial: "hello world")
    #expect(session.finishTurns() == "hello world")
}

@Test func hotkeyDefaultsDescribeRightOptionHold() {
    let config = HotkeyConfiguration()
    #expect(config.keyCode == 61)
    #expect(config.mode == .hold)
}

@Test func invalidHotkeyValuesFallBackPerField() throws {
    // A corrupted key code must not discard the stored mode (the whole-struct
    // decode used to throw and reset everything to defaults).
    let data = Data(#"{"keyCode":-5,"modifiers":-3,"mode":"toggle"}"#.utf8)
    let decoded = try JSONDecoder().decode(HotkeyConfiguration.self, from: data)
    #expect(decoded.keyCode == HotkeyConfiguration.defaultKeyCode)
    #expect(decoded.modifiers == 0)
    #expect(decoded.mode == .toggle)
}
