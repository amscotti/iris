import Testing

@testable import IrisCore

@Test func startupGateIsReadyWhenAllRequirementsMet() {
    let readiness = StartupReadiness.evaluate(
        microphoneGranted: true, accessibilityGranted: true, apiKeyPresent: true)
    #expect(readiness.isReady)
    #expect(readiness.missingItems.isEmpty)
}

@Test func startupGateBlocksOnMissingMicrophoneOnly() {
    let readiness = StartupReadiness.evaluate(
        microphoneGranted: false, accessibilityGranted: true, apiKeyPresent: true)
    #expect(!readiness.isReady)
    #expect(readiness.missingItems == [.microphone])
}

@Test func startupGateBlocksOnMissingAccessibilityOnly() {
    let readiness = StartupReadiness.evaluate(
        microphoneGranted: true, accessibilityGranted: false, apiKeyPresent: true)
    #expect(!readiness.isReady)
    #expect(readiness.missingItems == [.accessibility])
}

@Test func startupGateBlocksOnMissingAPIKeyOnly() {
    let readiness = StartupReadiness.evaluate(
        microphoneGranted: true, accessibilityGranted: true, apiKeyPresent: false)
    #expect(!readiness.isReady)
    #expect(readiness.missingItems == [.apiKey])
}

@Test func startupGateListsEveryBlockerInPresentationOrder() {
    let readiness = StartupReadiness.evaluate(
        microphoneGranted: false, accessibilityGranted: false, apiKeyPresent: false)
    #expect(!readiness.isReady)
    #expect(readiness.missingItems == [.microphone, .accessibility, .apiKey])
}

@Test func startupGateBlocksOnKeychainAccessInsteadOfAMissingKey() {
    let locked = StartupReadiness.evaluate(
        microphoneGranted: true, accessibilityGranted: true, apiKeyPresent: false,
        keyAccessUnavailable: true)
    #expect(!locked.isReady)
    #expect(locked.missingItems == [.keyAccess])
    let withMicrophone = StartupReadiness.evaluate(
        microphoneGranted: false, accessibilityGranted: true, apiKeyPresent: false,
        keyAccessUnavailable: true)
    #expect(withMicrophone.missingItems == [.microphone, .keyAccess])
}

@Test func startupGateReadinessRoundTripsThroughInit() {
    let readiness = StartupReadiness(microphoneGranted: true, accessibilityGranted: false, apiKeyPresent: true)
    #expect(!readiness.isReady)
    #expect(readiness.missingItems == [.accessibility])
    #expect(
        readiness
            == StartupReadiness.evaluate(
                microphoneGranted: true, accessibilityGranted: false, apiKeyPresent: true))
}
