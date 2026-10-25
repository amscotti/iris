import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func settingsBannerNamesTheRemainingProviderBlocker() {
    #expect(
        SettingsView.showsStatusBanner(
            loadIssue: nil, saveError: nil, requiresRelaunch: false, startupBlockers: [.apiKey]))
    #expect(SettingsView.startupBlockerSummary([.apiKey]) == "Setup needed: API key.")
    #expect(
        SettingsView.statusBannerAnnouncement(
            loadIssue: nil, saveError: nil, requiresRelaunch: false, startupBlockers: [.apiKey])
            == "Setup needed: API key.")
}

@Test @MainActor func grantedPermissionsWithAMissingKeyStillSurfaceSetupWithoutPoppingSettings() async {
    let environment = TestEnvironment().make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true))
    await environment.checkStartupGate(openSettingsWhenBlocked: false)

    #expect(environment.menuStartupBlockers == [.apiKey])
    #expect(environment.settingsWindowController == nil)
    #expect(
        SettingsView.showsStatusBanner(
            loadIssue: environment.settingsLoadIssue, saveError: environment.settingsSaveError,
            requiresRelaunch: environment.requiresRelaunch,
            startupBlockers: environment.menuStartupBlockers))
    #expect(SettingsView.startupBlockerSummary(environment.menuStartupBlockers) == "Setup needed: API key.")
    await environment.stop()
}
