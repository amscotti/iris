import Testing

@testable import IrisCore

@Test func noticeCategoriesDoNotDependOnPresentationMessages() {
    #expect(DictationNotice.insertion(.clipboardCopyFailed).category == .problem)
    #expect(DictationNotice.insertion(.restoreFailedDictationPreserved).category == .copied)
    #expect(DictationNotice.cancelled(.settingsChange).severity == .information)
    #expect(DictationNotice.noSpeech.severity == .warning)
    #expect(DictationNotice.restartRequired("anything").severity == .error)
    #expect(DictationNotice.failure("Copied to clipboard.").category == .problem)
    #expect(DictationNotice.failure("Copied to clipboard.").severity == .error)
    // The dictation was pasted; only the previous clipboard was lost.
    #expect(DictationNotice.insertion(.restoreFailedDictationLost).severity == .warning)
    #expect(DictationNotice.insertion(.restoreFailedDictationLost).category == .problem)
}
