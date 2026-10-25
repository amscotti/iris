import Foundation
import Testing

@testable import IrisMacOS

@Test @MainActor func microphoneStatusLabelsArePlainWords() {
    #expect(PermissionsManager.MicrophoneStatus.unknown.label == "Not determined")
    #expect(PermissionsManager.MicrophoneStatus.granted.label == "Granted")
    #expect(PermissionsManager.MicrophoneStatus.denied.label == "Denied")
    #expect(PermissionsManager.MicrophoneStatus.restricted.label == "Restricted")
}

@Test @MainActor func microphoneHeadingNamesRestrictedPolicy() {
    let fixture = TestEnvironment()
    func environment(_ status: PermissionsManager.MicrophoneStatus) -> AppEnvironment {
        fixture.make(permissions: PermissionsManager(microphoneStatus: status, accessibilityGranted: true))
    }
    #expect(environment(.granted).microphoneHeadingTitle == "Allowed")
    #expect(environment(.restricted).microphoneHeadingTitle == "Restricted by policy")
    #expect(environment(.denied).microphoneHeadingTitle == "Needs access")
    #expect(environment(.unknown).microphoneHeadingTitle == "Needs access")
}

@Test @MainActor func settingsDeepLinksParse() throws {
    let microphone = try #require(URL(string: PermissionsManager.microphoneSettingsURLString))
    #expect(microphone.scheme == "x-apple.systempreferences")
    let accessibility = try #require(URL(string: PermissionsManager.accessibilitySettingsURLString))
    #expect(accessibility.scheme == "x-apple.systempreferences")
}

@Test @MainActor func permissionCopyIsPresent() {
    #expect(!PermissionsManager.whyLine.isEmpty)
    #expect(!PermissionsManager.unbundledGuidance.isEmpty)
    #expect(!PermissionsManager.resetExplanation.isEmpty)
    #expect(!PermissionsManager.tccToolPath.isEmpty)
}

@Test @MainActor func resetCommandsScopeToOneBundleId() {
    #expect(PermissionsManager.resetCommands(bundleIdentifier: nil) == [])
    #expect(PermissionsManager.resetCommands(bundleIdentifier: "") == [])
    #expect(
        PermissionsManager.resetCommands(bundleIdentifier: "io.github.amscotti.iris") == [
            "tccutil reset Microphone io.github.amscotti.iris",
            "tccutil reset Accessibility io.github.amscotti.iris",
        ])
}

@Test @MainActor func diagnosticsLinesNameEachFact() {
    let report = PermissionDiagnostics(
        runsUnbundled: true,
        bundleIdentifier: nil,
        microphoneUsageDescriptionPresent: true,
        rawRecordPermission: "not requested yet",
        microphoneStatus: .unknown,
        accessibilityGranted: false)
    #expect(report.lines.count == 6)
    #expect(report.lines[0].contains("unbundled"))
    #expect(report.lines[1].contains("none"))
    #expect(report.lines[2].contains("present"))
    #expect(report.lines[3].contains("not requested yet"))
    #expect(report.lines[4].contains("Not determined"))
    #expect(report.lines[5].contains("not granted"))
    let bundled = PermissionDiagnostics(
        runsUnbundled: false,
        bundleIdentifier: "io.github.amscotti.iris",
        microphoneUsageDescriptionPresent: false,
        rawRecordPermission: "denied",
        microphoneStatus: .denied,
        accessibilityGranted: true)
    #expect(bundled.lines[0].contains("app bundle"))
    #expect(bundled.lines[1].contains("io.github.amscotti.iris"))
    #expect(bundled.lines[2].contains("missing"))
}

@Test @MainActor func guidanceNamesCurrentState() {
    let permissions = PermissionsManager()
    switch permissions.microphoneStatus {
    case .granted:
        #expect(permissions.microphoneGuidance.contains("Granted"))
    case .unknown:
        #expect(permissions.microphoneGuidance.contains("Not requested"))
    case .denied:
        #expect(permissions.microphoneGuidance.contains("Turned off"))
    case .restricted:
        #expect(permissions.microphoneGuidance.contains("system policy"))
    }
    #expect(!permissions.accessibilityGuidance.isEmpty)
    #expect(permissions.microphoneGranted == (permissions.microphoneStatus == .granted))
}

@Test @MainActor func diagnosticsMirrorsLiveState() {
    let permissions = PermissionsManager()
    let report = permissions.diagnostics()
    #expect(report.microphoneStatus == permissions.microphoneStatus)
    #expect(report.accessibilityGranted == permissions.accessibilityGranted)
    #expect(report.runsUnbundled == (Bundle.main.bundleIdentifier == nil))
    #expect(report.bundleIdentifier == Bundle.main.bundleIdentifier)
    #expect(report.lines.count == 6)
    #expect(
        permissions.resetCommandsForThisApp
            == PermissionsManager.resetCommands(bundleIdentifier: Bundle.main.bundleIdentifier))
}
