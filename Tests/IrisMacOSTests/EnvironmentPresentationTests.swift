import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

/// Environment-level status presentation: the retained notice kind drives
/// the resting menu line and symbol, and a successful final clears the busy
/// guidance the core already dropped from its snapshot.
@Test @MainActor func busyPressGuidanceIsPinnedToTheOrchestratorMessage() {
    #expect(NoticePresentation.busyPressGuidance == DictationOrchestrator.busyMessage)
}

@Test @MainActor func noticeKindsFollowSeverityAndCategory() {
    #expect(NoticePresentation.noticeKind(for: .cancelled(.settingsChange)) == .informational)
    #expect(NoticePresentation.noticeKind(for: .cancelled(.systemEvent)) == .informational)
    #expect(NoticePresentation.noticeKind(for: .cancelled(.microphoneDenied)) == .attention)
    #expect(NoticePresentation.noticeKind(for: .cancelled(.accessibilityDenied)) == .attention)
    #expect(NoticePresentation.noticeKind(for: .noSpeech) == .attention)
    #expect(NoticePresentation.noticeKind(for: .insertion(.secureField)) == .copied)
    #expect(NoticePresentation.noticeKind(for: .insertion(.clipboardWriteFailed)) == .failure)
    #expect(NoticePresentation.noticeKind(for: .failure("provider rejected the key")) == .failure)
    #expect(NoticePresentation.noticeKind(for: .restartRequired("restart needed")) == .failure)
    #expect(
        NoticePresentation.noticeKind(forSnapshotErrorMessage: NoticePresentation.busyPressGuidance)
            == .busy)
    #expect(NoticePresentation.noticeKind(forSnapshotErrorMessage: "Microphone unavailable.") == .failure)
}

private struct RestingStatusCase: Sendable {
    let kind: RetainedNoticeKind
    let message: String
    let line: String
    let symbol: String
}

@Test @MainActor func restingStatusFollowsTheRetainedNoticeKind() {
    let environment = TestEnvironment().make()
    let cases = [
        RestingStatusCase(
            kind: .busy, message: NoticePresentation.busyPressGuidance,
            line: "Finishing previous dictation…", symbol: "hourglass"),
        RestingStatusCase(
            kind: .copied, message: "Text was copied to the clipboard instead.",
            line: "Dictation copied to the clipboard", symbol: "doc.on.clipboard"),
        RestingStatusCase(
            kind: .informational, message: "The current dictation was cancelled.",
            line: "Dictation cancelled", symbol: "mic.fill"),
        RestingStatusCase(
            kind: .attention, message: "No speech was recognized.",
            line: "Dictation needs attention", symbol: "exclamationmark.triangle"),
        RestingStatusCase(
            kind: .failure, message: "Provider rejected the API key.",
            line: "Dictation error", symbol: "exclamationmark.triangle"),
    ]
    for testCase in cases {
        environment.retainNotice(testCase.message, kind: testCase.kind)
        environment.applyRestingStatus()
        #expect(environment.statusLine == testCase.line)
        #expect(environment.menuSymbol == testCase.symbol)
    }
}

@Test @MainActor func noticeBranchStillLosesToHigherPriorityRestingStates() {
    let environment = TestEnvironment().make()
    environment.retainNotice("Provider rejected the API key.", kind: .failure)
    environment.startupLimited = true
    environment.applyRestingStatus()
    #expect(environment.statusLine == "Iris setup needed")
    #expect(environment.menuSymbol == "exclamationmark.triangle")
    environment.startupLimited = false
    environment.applyRestingStatus()
    #expect(environment.statusLine == "Dictation error")
}

@Test @MainActor func successfulFinalClearsTheRetainedBusyGuidance() {
    let environment = TestEnvironment().make()
    let busy = NoticePresentation.busyPressGuidance
    environment.handleSnapshot(
        DictationSnapshot(
            state: .error(busy), lastError: busy, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .error(busy)))
    #expect(environment.lastDictationError == busy)
    #expect(environment.statusLine == "Finishing previous dictation…")
    #expect(environment.menuSymbol == "hourglass")
    #expect(environment.pill.noticeForTests == .problem)

    environment.handleSnapshot(
        DictationSnapshot(
            state: .final("hello"), lastError: nil, requiresRestart: false,
            terminalRevision: 2, lastTerminal: .final("hello")))
    #expect(environment.lastDictationError == nil)
    #expect(environment.statusLine == "Ready")
    #expect(environment.menuSymbol == "mic.fill")
    #expect(environment.pill.noticeForTests == nil)
    #expect(environment.pill.lastAnnouncement == "Dictation finished")

    // The trailing idle snapshot replays the terminal; the clear must hold.
    environment.handleSnapshot(
        DictationSnapshot(
            state: .idle, lastError: nil, requiresRestart: false,
            terminalRevision: 2, lastTerminal: .final("hello")))
    #expect(environment.lastDictationError == nil)
    #expect(environment.statusLine == "Ready")
    environment.pill.handle(.idle)
}

@Test @MainActor func busyPressRevisionSurfacesGuidanceWithoutReplacingTheFinal() {
    let environment = TestEnvironment().make()
    environment.handleSnapshot(
        DictationSnapshot(
            state: .final("hello"), lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("hello"), busyPressRevision: 0))
    #expect(environment.statusLine == "Ready")

    environment.handleSnapshot(
        DictationSnapshot(
            state: .idle, lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("hello"), busyPressRevision: 1))
    #expect(environment.lastDictationError == NoticePresentation.busyPressGuidance)
    #expect(environment.statusLine == "Finishing previous dictation…")
    #expect(environment.menuSymbol == "hourglass")
    environment.pill.handle(.idle)
}

@Test @MainActor func realFailuresAreNotClearedByAFinalReplay() {
    let environment = TestEnvironment().make()
    environment.handleStatus(.error("Provider rejected the API key."))
    environment.handleStatus(.final("a later take"))
    #expect(environment.lastDictationError == "Provider rejected the API key.")
    #expect(environment.statusLine == "Dictation error")
    #expect(environment.menuSymbol == "exclamationmark.triangle")
}

@Test func restrictedMicrophoneIsItsOwnStartupBlocker() {
    let restricted = StartupReadiness.evaluate(
        microphoneGranted: false, accessibilityGranted: true, apiKeyPresent: true,
        microphoneRestricted: true)
    #expect(!restricted.isReady)
    #expect(restricted.missingItems == [.microphoneBlockedByPolicy])
    let denied = StartupReadiness.evaluate(
        microphoneGranted: false, accessibilityGranted: true, apiKeyPresent: true)
    #expect(denied.missingItems == [.microphone])
}

@Test @MainActor func menuBlockersNamePolicyRestrictedMicrophones() {
    let restricted = TestEnvironment().make(
        permissions: PermissionsManager(microphoneStatus: .restricted, accessibilityGranted: true))
    restricted.startupBlockers = [.microphone, .apiKey]
    #expect(restricted.menuStartupBlockers == [.microphoneBlockedByPolicy, .apiKey])

    let ordinary = TestEnvironment().make()
    ordinary.startupBlockers = [.microphone, .apiKey]
    #expect(ordinary.menuStartupBlockers == [.microphone, .apiKey])
}

@Test func settingsBannerAnnouncementNamesEveryVisibleProblem() {
    #expect(SettingsView.statusBannerAnnouncement(loadIssue: nil, saveError: nil, requiresRelaunch: false) == nil)
    #expect(
        SettingsView.statusBannerAnnouncement(
            loadIssue: "Settings could not be read.", saveError: "Changes could not be saved.",
            requiresRelaunch: true)
            == "Restart Iris to resume dictation. Changes could not be saved. Settings could not be read.")
}

@Test func settingsBannerIncludesTheRestartBlockedState() {
    #expect(!SettingsView.showsStatusBanner(loadIssue: nil, saveError: nil, requiresRelaunch: false))
    #expect(SettingsView.showsStatusBanner(loadIssue: nil, saveError: nil, requiresRelaunch: true))
    #expect(SettingsView.showsStatusBanner(loadIssue: "unreadable", saveError: nil, requiresRelaunch: false))
    #expect(SettingsView.showsStatusBanner(loadIssue: nil, saveError: "applies until quit", requiresRelaunch: false))
}

@Test @MainActor func stoppingTheEnvironmentReleasesAndCanRebuildTheSettingsWindow() async {
    let environment = TestEnvironment().make()
    environment.openSettingsWindow()
    #expect(environment.settingsWindowController != nil)
    await environment.stop()
    #expect(environment.settingsWindowController == nil)
    environment.openSettingsWindow()
    #expect(environment.settingsWindowController != nil)
    await environment.stop()
    #expect(environment.settingsWindowController == nil)
}
