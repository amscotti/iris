import Foundation
import Testing

@testable import IrisMacOS

@Test func nativeInputStallFailsAtTheConservativeBoundOnlyOnce() {
    let bound = AVAudioEngineCapturer.nativeInputFailureSeconds
    #expect(bound == 3)
    #expect(
        !AVAudioEngineCapturer.shouldReportNativeInputStall(
            secondsSinceNativeInput: 0, alreadyReported: false))
    #expect(
        !AVAudioEngineCapturer.shouldReportNativeInputStall(
            secondsSinceNativeInput: bound - 0.001, alreadyReported: false))
    #expect(
        AVAudioEngineCapturer.shouldReportNativeInputStall(
            secondsSinceNativeInput: bound, alreadyReported: false))

    // The production latch is set before invoking the failure callback, so
    // later pacer ticks cannot report the same dead tap again.
    #expect(
        !AVAudioEngineCapturer.shouldReportNativeInputStall(
            secondsSinceNativeInput: bound + 10, alreadyReported: true))
}

@Test func nativeHeartbeatIsRecordedBeforeConversion() {
    let pool = AVAudioEngineCapturer.NativeChunkPool(capacity: 1, pooledCount: 1)
    let start = 100.0
    pool.resetNativeInput(at: start)
    #expect(pool.secondsSinceNativeInput(now: start + 4) >= 3)
    pool.markNativeInput(at: start + 3.9)
    #expect(pool.secondsSinceNativeInput(now: start + 4) < 0.2)
}

@Test func healthyNativeCadenceDoesNotTripTheWatchdog() {
    // Silent PCM still arrives as native chunks and refreshes this age. Pacer
    // output is deliberately absent from the decision.
    for _ in 0..<100 {
        #expect(
            !AVAudioEngineCapturer.shouldReportNativeInputStall(
                secondsSinceNativeInput: 0.17, alreadyReported: false))
    }
}
