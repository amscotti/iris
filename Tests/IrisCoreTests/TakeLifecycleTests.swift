import Testing

@testable import IrisCore

@Test func startupReleaseCannotBeResurrectedByALateCaptureACK() {
    var lifecycle = TakeLifecycle()
    #expect(lifecycle.release() == .cancelStartup)
    let lateACK = lifecycle.captureReady()
    #expect(!lateACK)
    #expect(lifecycle.release() == .ignored)
    #expect(lifecycle.phase == .finalizing)
}

@Test func aRecordedTakeFinalizesExactlyOnce() {
    var lifecycle = TakeLifecycle()
    let firstACK = lifecycle.captureReady()
    let repeatedACK = lifecycle.captureReady()
    #expect(firstACK)
    #expect(!repeatedACK)
    #expect(lifecycle.phase == .recording)
    #expect(lifecycle.release() == .finishRecording)
    #expect(lifecycle.release() == .ignored)
    let lateACK = lifecycle.captureReady()
    #expect(!lateACK)
}

@Test(arguments: [false, true]) func takeFailureRejectsLateReadinessAndRelease(recording: Bool) {
    var lifecycle = TakeLifecycle()
    if recording { lifecycle.captureReady() }
    lifecycle.fail()
    let lateACK = lifecycle.captureReady()
    #expect(!lateACK)
    #expect(lifecycle.release() == .ignored)
    lifecycle.fail()
    #expect(lifecycle.phase == .finalizing)
}
