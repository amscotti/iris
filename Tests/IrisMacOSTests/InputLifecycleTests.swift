import AppKit
import Testing

@testable import IrisCore
@testable import IrisMacOS

@MainActor
private func readyInputEnvironment() async throws -> (AppEnvironment, TestHotkeyEvents) {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let events = TestHotkeyEvents()
    let environment = fixture.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        hotkey: GlobalHotkeyMonitor(backend: events))
    await environment.start()
    return (environment, events)
}

@Test @MainActor func permissionChangesSuspendAndResumeFreshObservers() async throws {
    let (environment, events) = try await readyInputEnvironment()
    #expect(environment.runtime.isMonitoring)
    #expect(environment.settingsWindowController == nil)
    await environment.beginPermissionChange()
    #expect(environment.permissionOperationInProgress)
    #expect(!environment.runtime.isMonitoring)
    #expect(environment.runtime.captureSuspended)
    events.keyPressed = true
    environment.endPermissionChange()
    #expect(environment.runtime.isMonitoring)
    // The suspended monitor's observer was genuinely removed: exactly one
    // live global handler after the restart, no accumulation.
    #expect(events.globalHandlers.count == 1)
    // The refresh also probes the held key to reconcile a release lost while
    // monitoring was suspended, in addition to the two monitor-start probes.
    #expect(events.physicalReads == 4)
    #expect(!environment.runtime.captureSuspended)
    await environment.stop()
}

@Test @MainActor func overlappingPermissionOperationsRemainSuspendedUntilBothFinish() async throws {
    let (environment, _) = try await readyInputEnvironment()
    await environment.beginPermissionChange()
    await environment.beginPermissionChange()
    environment.endPermissionChange()
    #expect(!environment.runtime.isMonitoring)
    #expect(environment.permissionOperationInProgress)
    environment.endPermissionChange()
    #expect(environment.runtime.isMonitoring)
    await environment.stop()
}

@Test @MainActor func sleepWakeCancelsTheOldInputGenerationBeforeResuming() async throws {
    let (environment, events) = try await readyInputEnvironment()
    environment.runtime.handle(.sleep)
    #expect(!environment.runtime.isMonitoring)
    #expect(environment.runtime.captureSuspended)
    environment.runtime.handle(.wake)
    await environment.runtime.waitForCleanup()
    #expect(environment.runtime.isMonitoring)
    // Fresh observer after the wake restart, old one removed: never two.
    #expect(events.globalHandlers.count == 1)
    await environment.stop()
    environment.runtime.handle(.wake)
    #expect(!environment.runtime.isMonitoring)
}

@Test @MainActor func permissionChangeDuringATakeNotifiesInsteadOfVanishing() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let runtimeFixture = RuntimeFixture()
    let environment = fixture.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: runtimeFixture.ports())
    await environment.start()
    try await runtimeFixture.beginRecordedTake(in: environment)
    #expect(environment.statusLine == "Listening…")
    await environment.beginPermissionChange()
    #expect(environment.lastDictationError?.contains("cancelled") == true)
    environment.endPermissionChange()
    await environment.stop()
}
