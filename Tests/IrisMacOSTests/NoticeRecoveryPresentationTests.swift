import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func userRequestedCancellationHasInformationalPresentation() {
    let notice = DictationNotice.cancelled(.userRequested)
    #expect(NoticePresentation.message(for: notice) == "The current dictation was cancelled at your request.")
    #expect(notice.severity == .information)
    #expect(NoticePresentation.noticeKind(for: notice) == .informational)
    #expect(PillNotice(notice: notice) == .info)
}

@Test func preservedClipboardRestoreLeadsWithTheCompletedPaste() {
    #expect(
        NoticePresentation.message(for: .insertion(.restoreFailedDictationPreserved))
            == "Your words were already pasted. The previous clipboard couldn’t be restored; "
            + "the transcript remains on the clipboard.")
}
