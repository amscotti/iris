import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func startupGateBlockerLabelsNameWhatToFix() {
    #expect(StartupReadiness.MissingItem.microphone.label == "Microphone access")
    #expect(StartupReadiness.MissingItem.microphoneBlockedByPolicy.label == "Microphone access (blocked by policy)")
    #expect(StartupReadiness.MissingItem.accessibility.label == "Accessibility access")
    #expect(StartupReadiness.MissingItem.apiKey.label == "API key")
    #expect(StartupReadiness.MissingItem.keyAccess.label == "Keychain access")
}

@Test @MainActor func pillControllerNewTakeReplacesLevelHistory() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    controller.handle(.final("hello"))
    #expect(controller.hasPendingHideForTests)
    #expect(controller.levelHistoryForTests == [0.3])
    controller.handle(.recording(level: 0.8))
    #expect(controller.levelHistoryForTests == [0.8])
    controller.handle(.idle)
}

@Test(arguments: [PushToTalkState.final("previous take"), .final(""), .error("provider failure")])
@MainActor func pillControllerPartialFirstNewTakeReplacesLevelHistory(previousTerminal: PushToTalkState) {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.handle(.recording(level: 0.6))
    controller.handle(previousTerminal)
    #expect(controller.hasPendingHideForTests)

    controller.handle(.partial("new take"))
    #expect(controller.levelHistoryForTests.isEmpty)
    #expect(controller.noticeForTests == nil)
    #expect(controller.lastAnnouncement == "Recording")
    #expect(!controller.hasPendingHideForTests)
    controller.handle(.partial("new take continued"))
    controller.handle(.recording(level: 0.1))
    #expect(controller.levelHistoryForTests == [0.1])
    controller.handle(.partial("more words"))
    controller.handle(.recording(level: 0.2))
    #expect(controller.levelHistoryForTests == [0.1, 0.2])
}

@Test @MainActor func pillControllerPartialUpdatesPreserveTheCurrentTakesLevels() {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.handle(.recording(level: 0.6))
    controller.handle(.partial("same take"))
    #expect(controller.levelHistoryForTests == [0.6])
    controller.handle(.recording(level: 0.1))
    #expect(controller.levelHistoryForTests == [0.6, 0.1])
}

@Test func everyInsertionReasonHasExplicitPresentationGuidance() {
    #expect(Set(NoticePresentation.insertionMessages.keys) == Set(InsertionNotice.allCases))
    #expect(
        NoticePresentation.insertionMessages.values.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
}

@Test func diagnosticNoticeLabelsNeverIncludeProviderErrorOrCredentialDetails() {
    let secret = "fixture secret transcript key"
    #expect(NoticePresentation.logLabel(for: .failure(secret)) == "failure")
    #expect(NoticePresentation.logLabel(for: .restartRequired(secret)) == "restart-required")
    #expect(NoticePresentation.logLabel(for: .cancelled(.microphoneDenied)) == "cancelled")
}

@Test func pillNoticeDistinguishesClipboardFallbacksFromProblems() {
    let copied: Set<InsertionNotice> = [
        .accessibilityOff, .secureField, .keystrokesUnavailable, .partialClipboard, .pastePostFailed,
        .previousClipboardUnavailable, .concealedClipboardNotRestored, .restoreFailedDictationPreserved,
    ]
    for reason in InsertionNotice.allCases {
        #expect(PillNotice(category: reason.category) == (copied.contains(reason) ? .copied : .problem))
    }
}

@Test @MainActor func noticeWordingCannotChangeItsIconOrSeverity() {
    let controller = makeTestPillController()
    let failure = DictationNotice.failure("is on the clipboard — this arbitrary detail still describes failure")
    controller.handle(failure)
    #expect(controller.noticeForTests == .problem)
    #expect(failure.severity == .error)
    controller.handle(DictationNotice.insertion(.secureField))
    #expect(controller.noticeForTests == .copied)
    #expect(controller.lastAnnouncement == NoticePresentation.message(for: .insertion(.secureField)))
    controller.handle(.idle)
}

@Test @MainActor func pillControllerShowsNoticesAtTheCursorBeforeHiding() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.4))
    controller.handle(.error("The speech service disconnected before finishing. Try again."))
    #expect(controller.isVisibleForTests)
    #expect(controller.noticeForTests == .problem)
    #expect(controller.hasPendingHideForTests)
    // The idle that follows an error must not cut the notice short.
    controller.handle(.idle)
    #expect(controller.isVisibleForTests)
    #expect(controller.hasPendingHideForTests)
}

@Test @MainActor func pillControllerFlagsAnEmptyTranscript() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.2))
    controller.handle(.final("  "))
    #expect(controller.noticeForTests == .problem)
    #expect(controller.lastAnnouncement == NoticePresentation.message(for: .noSpeech))
    controller.handle(.idle)
}

@Test @MainActor func pillAnnouncesRecordingAndNoticesToVoiceOver() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    #expect(controller.lastAnnouncement == "Recording")
    controller.clearLastAnnouncementForTests()
    controller.handle(.recording(level: 0.5))
    // Continuing levels within one take do not re-announce.
    #expect(controller.lastAnnouncement == nil)
    controller.handle(.error("The speech service disconnected before finishing. Try again."))
    #expect(controller.lastAnnouncement == "The speech service disconnected before finishing. Try again.")
    controller.handle(.idle)
}

@Test func informationalCancellationsRenderAsInfoNotProblem() {
    #expect(PillNotice(notice: .cancelled(.settingsChange)) == .info)
    #expect(PillNotice(notice: .cancelled(.systemEvent)) == .info)
    #expect(PillNotice(notice: .cancelled(.microphoneDenied)) == .problem)
    #expect(PillNotice(notice: .insertion(.secureField)) == .copied)
    #expect(PillNotice(notice: .failure("boom")) == .problem)
    #expect(PillNotice.info.visibilityNanoseconds < PillNotice.problem.visibilityNanoseconds)
    #expect(PillNotice.info.visibilityNanoseconds == PillNotice.copied.visibilityNanoseconds)
}

@Test @MainActor func rewriteFinalDoesNotAnnounceFinishedTwice() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    controller.handle(.final("raw words"))
    #expect(controller.lastAnnouncement == "Dictation finished")
    controller.handle(.enhancing)
    #expect(controller.lastAnnouncement == "Rewriting")
    controller.handle(.final("rewritten words"))
    // The post-rewrite final completes the same take: no second announcement.
    #expect(controller.lastAnnouncement == "Rewriting")
    controller.handle(.idle)
}

@Test @MainActor func recordingAfterANoticeClearsItAndAnnounces() {
    let controller = makeTestPillController()
    controller.handle(.error("boom"))
    #expect(controller.noticeForTests == .problem)
    #expect(controller.isVisibleForTests)
    // The next take must not show the previous take's warning icon, and
    // VoiceOver hears the new recording even though the pill stayed visible.
    controller.handle(.recording(level: 0.3))
    #expect(controller.noticeForTests == nil)
    #expect(controller.lastAnnouncement == "Recording")
    controller.handle(.idle)
}

@Test @MainActor func finalAnnouncesCompletionAndDropsARetainedProblemNotice() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    // Busy-press guidance adopted while the take was finishing.
    controller.handle(.error("Finishing previous dictation — try again in a moment."))
    #expect(controller.noticeForTests == .problem)
    controller.handle(.final("hello"))
    // The finished take supersedes the stale warning glyph, and VoiceOver
    // hears the completion the lingering pill could never focus to read.
    #expect(controller.noticeForTests == nil)
    #expect(controller.lastAnnouncement == "Dictation finished")
    #expect(controller.isVisibleForTests)
    #expect(controller.hasPendingHideForTests)
    controller.handle(.idle)
}

@Test @MainActor func finalKeepsACopiedNoticeFromItsOwnTake() {
    let controller = makeTestPillController()
    controller.handle(DictationNotice.insertion(.pastePostFailed))
    #expect(controller.noticeForTests == .copied)
    controller.handle(.final("hello"))
    // Copied notices describe this take's insertion and are not busy residue.
    #expect(controller.noticeForTests == .copied)
    #expect(controller.lastAnnouncement == "Dictation finished")
    controller.handle(.idle)
}

@Test func lostClipboardRestoreCopyLeadsWithTheSuccessfulPaste() {
    #expect(
        NoticePresentation.insertionMessages[.restoreFailedDictationLost]
            == "Your words were pasted; the previous clipboard couldn’t be restored or kept.")
}

@Test @MainActor func effectiveReduceMotionMatchesTheLivePillRule() {
    #expect(PillController.effectiveReduceMotion(forcing: false, system: false) == false)
    #expect(PillController.effectiveReduceMotion(forcing: true, system: false) == true)
    #expect(PillController.effectiveReduceMotion(forcing: false, system: true) == true)
    #expect(PillController.effectiveReduceMotion(forcing: true, system: true) == true)
}
