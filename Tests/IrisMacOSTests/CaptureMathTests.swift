import AVFoundation
import Foundation
import IrisCore
import Testing

@testable import IrisMacOS

private func stereoBuffer(left: [Float], right: [Float]) throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
    buffer.frameLength = AVAudioFrameCount(left.count)
    let channels = try #require(buffer.floatChannelData)
    for (index, value) in left.enumerated() {
        channels[0][index] = value
    }
    for (index, value) in right.enumerated() {
        channels[1][index] = value
    }
    return buffer
}

@Test func capturerResolvesSupportedRates() async {
    #expect(AVAudioEngineCapturer.supportedSampleRates == [16000, 24000])
    #expect(await AVAudioEngineCapturer().sampleRate == 16000)
    #expect(await AVAudioEngineCapturer(targetSampleRate: 24000).sampleRate == 24000)
    #expect(await AVAudioEngineCapturer(targetSampleRate: 8000).sampleRate == 16000)
}

@Test func monoMixFillsReusableTapStorage() throws {
    let buffer = try stereoBuffer(left: [1, 2, 3, 4], right: [3, 2, 1, 0])
    var storage = [Float](repeating: 99, count: 8)
    let capacity = storage.capacity
    let count = AVAudioEngineCapturer.monoMix(buffer: buffer, into: &storage)
    #expect(count == 4)
    #expect(storage == [2, 2, 2, 2])
    #expect(storage.capacity == capacity)
}

@Test func monoMixAveragesChannels() throws {
    let buffer = try stereoBuffer(left: [1, 2, 3, 4], right: [3, 2, 1, 0])
    #expect(AVAudioEngineCapturer.monoMix(buffer: buffer) == [2, 2, 2, 2])
}

@Test func monoMixIgnoresEmptyBuffers() throws {
    let buffer = try stereoBuffer(left: [1, 2], right: [1, 2])
    buffer.frameLength = 0
    #expect(AVAudioEngineCapturer.monoMix(buffer: buffer) == [])
}

@Test func monoMixCountsNonFloatBuffersAsEmpty() throws {
    // Int16/interleaved hardware shapes have no floatChannelData: the mix
    // is empty, which the conversion stage must count as a failed
    // conversion rather than dropping the buffer silently.
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    #expect(buffer.floatChannelData == nil)
    #expect(AVAudioEngineCapturer.monoMix(buffer: buffer) == [])
}

@Test func monoMixCountsInterleavedStereoAsEmpty() throws {
    // Interleaved float stereo has floatChannelData but no per-channel
    // pointers; indexing channels[1] would read outside the block.
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    #expect(buffer.format.isInterleaved)
    #expect(AVAudioEngineCapturer.monoMix(buffer: buffer) == [])
}

@Test func emptyConversionsFailTheTakeOnlyAfterTheBound() {
    var health = AVAudioEngineCapturer.ConversionHealth(failureBound: 5)
    // Failed conversions accumulate silently until the bound...
    for _ in 0..<4 {
        let reported = health.record(producedSamples: 0)
        #expect(!reported)
    }
    let reported63 = health.record(producedSamples: 0)
    #expect(reported63 == true)
    // ...and keep failing without re-reporting.
    let reported65 = health.record(producedSamples: 0)
    #expect(reported65 == false)
    // A producing conversion resets the run: only failures after it count.
    let reset = health.record(producedSamples: 1600)
    #expect(!reset)
    for _ in 0..<4 {
        let reported = health.record(producedSamples: 0)
        #expect(!reported)
    }
    let reportedAgain = health.record(producedSamples: 0)
    #expect(reportedAgain)
}

@Test func healthySilenceNeverTripsTheEmptyConversionBound() {
    // Quiet audio still converts to real (zero-valued) samples: a long
    // silent take must not be mistaken for a starving one.
    var health = AVAudioEngineCapturer.ConversionHealth(failureBound: 5)
    for _ in 0..<100 {
        let reported = health.record(producedSamples: 1600)
        #expect(!reported)
    }
    // A failure run interrupted by produced samples does not accumulate
    // across the interruption.
    for _ in 0..<4 {
        let reported = health.record(producedSamples: 0)
        #expect(!reported)
    }
    let reported90 = health.record(producedSamples: 1600)
    #expect(reported90 == false)
    for _ in 0..<4 {
        let reported = health.record(producedSamples: 0)
        #expect(!reported)
    }
    let reported95 = health.record(producedSamples: 0)
    #expect(reported95 == true)
}

@Test func teardownTailBelongsToTheStopThatDrained() {
    // The stop still owns its generation: leftovers flush, the stream ends.
    #expect(
        AVAudioEngineCapturer.teardownTail(stoppedGeneration: 5, currentGeneration: 5, pendingSamples: 640)
            == .finish(flushPendingSamples: true))
    #expect(
        AVAudioEngineCapturer.teardownTail(stoppedGeneration: 5, currentGeneration: 5, pendingSamples: 0)
            == .finish(flushPendingSamples: false))
    // A press started while the drain was suspended owns the stream: the
    // stale stop's tail must not flush into it or finish it.
    #expect(
        AVAudioEngineCapturer.teardownTail(stoppedGeneration: 5, currentGeneration: 6, pendingSamples: 640)
            == .superseded)
}

@Test func conversionDownsamplesHardwareRates() async {
    let capturer = AVAudioEngineCapturer(targetSampleRate: 16_000)
    let first = AVAudioEngineCapturer.NativeChunk(
        monoSamples: [Float](repeating: 0.1, count: 4096), sourceSampleRate: 48_000)
    var produced48k = 0
    for _ in 0..<4 {
        produced48k += await capturer.convert(chunk: first).count
    }
    #expect(produced48k > 4_000)
    let second = AVAudioEngineCapturer.NativeChunk(
        monoSamples: [Float](repeating: 0.1, count: 4096), sourceSampleRate: 44_100)
    var produced44k = 0
    for _ in 0..<4 {
        produced44k += await capturer.convert(chunk: second).count
    }
    #expect(produced44k > 4_000)
    #expect(
        await capturer.convert(
            chunk: AVAudioEngineCapturer.NativeChunk(monoSamples: [], sourceSampleRate: 48_000)
        ).isEmpty)
    #expect(
        await capturer.convert(
            chunk: AVAudioEngineCapturer.NativeChunk(
                monoSamples: [Float](repeating: 0.1, count: 64), sourceSampleRate: 0)
        ).isEmpty)
}

@Test func captureErrorsCompareByCase() {
    #expect(CaptureError.unavailable == CaptureError.unavailable)
    #expect(CaptureError.notAuthorized == CaptureError.notAuthorized)
    #expect(CaptureError.startFailed("x") == CaptureError.startFailed("x"))
    #expect(CaptureError.unavailable != CaptureError.startFailed("x"))
    #expect(CaptureError.notAuthorized != CaptureError.unavailable)
    #expect(CaptureError.notAuthorized != CaptureError.startFailed("x"))
}

@Test func terminalRemainderPadsToCanonicalFrame() {
    let full = AVAudioEngineCapturer.padTerminalSamples([1, 2, 3], to: 1600)
    #expect(full.count == 1600)
    #expect(Array(full.prefix(3)) == [1, 2, 3])
    #expect(full.dropFirst(3).allSatisfy { $0 == 0 })
    #expect(AVAudioEngineCapturer.padTerminalSamples([], to: 1600).count == 1600)
    let exact = AVAudioEngineCapturer.padTerminalSamples([Int16](repeating: 7, count: 1600), to: 1600)
    #expect(exact == [Int16](repeating: 7, count: 1600))
}

@Test func silencePacerOnlyFiresAfterARealStall() {
    let frame = PCMFrame.samplesPerFrame(sampleRate: 16000)
    // Normal cadences (48 kHz built-in ~85 ms, Bluetooth HFP ~170 ms) are far
    // inside the threshold: a pending partial frame is not a stall.
    #expect(
        AVAudioEngineCapturer.pacerAction(pendingSamples: 1130, frameSampleCount: frame, secondsSinceInput: 0.1)
            == .none)
    #expect(
        AVAudioEngineCapturer.pacerAction(pendingSamples: 1130, frameSampleCount: frame, secondsSinceInput: 0.17)
            == .none)
    // A stalled tap with real samples pending flushes them, never silence.
    #expect(
        AVAudioEngineCapturer.pacerAction(pendingSamples: 1130, frameSampleCount: frame, secondsSinceInput: 0.31)
            == .flushPartial)
    // A stalled tap with nothing pending keeps the stream alive.
    #expect(
        AVAudioEngineCapturer.pacerAction(pendingSamples: 0, frameSampleCount: frame, secondsSinceInput: 0.31)
            == .silence)
}
