import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func relaunchCommandWaitsForThisProcessThenReopensTheBundle() {
    let arguments = AppRelauncher.shellArguments(bundlePath: "/Applications/Iris.app", pid: 4242)
    #expect(arguments.count == 4)
    #expect(arguments[0] == "-c")
    #expect(arguments[1].contains("/usr/bin/open"))
    #expect(arguments[1].contains("$1"))
    #expect(arguments[2] == "/Applications/Iris.app")
    #expect(arguments[3] == "4242")
}

@Test func menuGuidancePrioritizesRelaunchThenSetupThenHint() {
    #expect(
        MenuBarContent.guidanceSection(requiresRelaunch: true, hasSettingsLoadIssue: true, startupLimited: true)
            == .relaunch)
    #expect(
        MenuBarContent.guidanceSection(requiresRelaunch: false, hasSettingsLoadIssue: true, startupLimited: false)
            == .setup)
    #expect(
        MenuBarContent.guidanceSection(requiresRelaunch: false, hasSettingsLoadIssue: false, startupLimited: true)
            == .setup)
    #expect(
        MenuBarContent.guidanceSection(requiresRelaunch: false, hasSettingsLoadIssue: false, startupLimited: false)
            == .dictationHint)
    #expect(
        MenuBarContent.guidanceSection(
            requiresRelaunch: false, hasSettingsLoadIssue: false, startupLimited: false, startupComplete: false)
            == .setup)
}

@Test @MainActor func setupStepsNameTheFixAndTheActiveProvider() {
    #expect(
        MenuBarContent.setupStepLabel(for: .microphone, providerName: "Meta") == "Allow Microphone Access…")
    #expect(
        MenuBarContent.setupStepLabel(for: .microphoneBlockedByPolicy, providerName: "Meta")
            == "Microphone blocked by system policy…")
    #expect(
        MenuBarContent.setupStepLabel(for: .accessibility, providerName: "Meta")
            == "Allow Accessibility Access…")
    #expect(MenuBarContent.setupStepLabel(for: .apiKey, providerName: "Grok") == "Add Grok API Key…")
    #expect(
        MenuBarContent.setupStepLabel(for: .keyAccess, providerName: "Meta") == "Unlock Keychain for Meta…")
}

@Test func relaunchRequiresARealNonTranslocatedBundle() {
    #expect(AppRelauncher.isRelaunchableBundle(path: "/Applications/Iris.app", pathExtension: "app"))
    #expect(
        !AppRelauncher.isRelaunchableBundle(
            path: "/private/var/folders/AppTranslocation/UUID/Iris.app", pathExtension: "app"))
    #expect(!AppRelauncher.isRelaunchableBundle(path: "/tmp/IrisMacOS", pathExtension: ""))
}
