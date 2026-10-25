import Testing

@testable import IrisMacOS

@Test(arguments: [false, true]) func inputReadinessWaitsForEveryBlockerToClear(cleaningUp: Bool) {
    var readiness = InputReadiness(
        started: true, systemAwake: false, sessionActive: false, permissionOperations: 2,
        microphoneGranted: false, accessibilityGranted: false, cleaningUp: cleaningUp, restartReason: nil)
    func blocked(_ reason: InputSuspensionReason) -> InputRuntimeState {
        cleaningUp ? .cleaningUp(reason) : .suspended(reason)
    }
    #expect(readiness.state == blocked(.systemAsleep))
    readiness.systemAwake = true
    #expect(readiness.state == blocked(.sessionInactive))
    readiness.sessionActive = true
    #expect(readiness.state == blocked(.permissionOperation))
    readiness.permissionOperations = 1
    #expect(readiness.state == blocked(.permissionOperation))
    readiness.permissionOperations = 0
    #expect(readiness.state == blocked(.microphoneDenied))
    readiness.microphoneGranted = true
    #expect(readiness.state == blocked(.accessibilityDenied))
    readiness.accessibilityGranted = true
    #expect(readiness.state == (cleaningUp ? .cleaningUp(.cleaningUpPreviousGeneration) : .ready))
    readiness.cleaningUp = false
    #expect(readiness.state == .ready)
}

@Test(arguments: [false, true]) func restartLatchOverridesStopAndCleanup(cleaningUp: Bool) {
    var readiness = InputReadiness(
        started: false, systemAwake: false, sessionActive: false, permissionOperations: 1,
        microphoneGranted: false, accessibilityGranted: false, cleaningUp: cleaningUp, restartReason: nil)
    #expect(readiness.state == .stopped)
    readiness.restartReason = "Previous input generation did not stop."
    #expect(readiness.state == .restartRequired("Previous input generation did not stop."))
    readiness.started = true
    readiness.systemAwake = true
    readiness.sessionActive = true
    readiness.permissionOperations = 0
    readiness.microphoneGranted = true
    readiness.accessibilityGranted = true
    readiness.cleaningUp = false
    #expect(!readiness.state.isReady)
}
