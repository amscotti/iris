import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func stopClearsPendingGateIntentAndLeavesNoMonitoring() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = fixture.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true))
    await environment.start()
    #expect(environment.runtime.isMonitoring)

    environment.openSettingsPending = true
    await environment.stop()

    #expect(!environment.openSettingsPending)
    #expect(!environment.startupGateHold)
    #expect(!environment.runtime.isStarted)
    #expect(!environment.runtime.isMonitoring)

    // A late gate task is a no-op after teardown and cannot reopen Settings.
    await environment.checkStartupGate(openSettingsWhenBlocked: true)
    #expect(environment.settingsWindowController == nil)
}
