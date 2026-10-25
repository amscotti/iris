import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func finalDictationSurvivesInsertionFailureUntilAnExplicitCopy() {
    let originalClipboard = "clipboard owned by the user"
    let transcript = "words to recover"
    let clipboard = FakeClipboard(string: originalClipboard)
    let environment = TestEnvironment().make(clipboard: clipboard)

    #expect(!environment.copyLastDictationToClipboard())
    environment.handleStatus(.final(transcript))
    #expect(environment.lastDictationText == transcript)
    #expect(clipboard.string() == originalClipboard)

    let notice = DictationNotice.insertion(.clipboardChangedBeforePaste)
    environment.retainNotice(
        NoticePresentation.message(for: notice), kind: NoticePresentation.noticeKind(for: notice))
    #expect(environment.lastDictationError == NoticePresentation.message(for: notice))
    #expect(environment.lastDictationText == transcript)
    #expect(clipboard.string() == originalClipboard)

    #expect(environment.copyLastDictationToClipboard())
    #expect(clipboard.string() == transcript)
}

@Test @MainActor func failedRecoveryCopySurfacesANotice() {
    let clipboard = FakeClipboard()
    clipboard.setSucceeds = false
    let environment = TestEnvironment().make(clipboard: clipboard)
    environment.handleStatus(.final("recoverable words"))

    #expect(!environment.copyLastDictationToClipboard())
    #expect(environment.lastDictationText == "recoverable words")
    #expect(
        environment.lastDictationError
            == NoticePresentation.message(for: .insertion(.clipboardCopyFailed)))

    clipboard.setSucceeds = true
    #expect(environment.copyLastDictationToClipboard())
    #expect(environment.lastDictationError == nil)
    #expect(environment.statusLine == "Ready")
}

@Test @MainActor func blankFinalDoesNotReplaceTheRecoverableDictation() {
    let environment = TestEnvironment().make()
    environment.handleStatus(.final("latest non-empty final"))
    environment.handleStatus(.final(" \n "))
    #expect(environment.lastDictationText == "latest non-empty final")
}

@Test @MainActor func takeSnapshotsGateTheRuntimeCancellationRequest() async throws {
    let environment = TestEnvironment().make()
    let probe = DictationCancellationProbe()
    environment.cancelDictationForTesting = { _ in await probe.cancel() }
    defer { environment.pill.handle(.idle) }

    environment.cancelDictation()
    await Task.yield()
    #expect(probe.calls == 0)

    environment.handleSnapshot(recoverySnapshot(state: .recording(level: 0.2), isTakeActive: true))
    #expect(environment.isTakeActive)
    environment.cancelDictation()
    try await AsyncDeadline.run(seconds: 1) { @MainActor in
        while probe.calls == 0 { await Task.yield() }
    }
    #expect(probe.calls == 1)

    environment.handleSnapshot(recoverySnapshot(state: .idle, isTakeActive: false))
    #expect(!environment.isTakeActive)
    #expect(!environment.canCancelDictation)
    environment.cancelDictation()
    await Task.yield()
    #expect(probe.calls == 1)
}

private func recoverySnapshot(state: PushToTalkState, isTakeActive: Bool) -> DictationSnapshot {
    DictationSnapshot(
        state: state, lastError: nil, requiresRestart: false,
        terminalRevision: 0, lastTerminal: nil, isTakeActive: isTakeActive,
        activeTakeID: isTakeActive ? 1 : nil)
}

@MainActor
private final class DictationCancellationProbe {
    private(set) var calls = 0

    func cancel() async -> Bool {
        calls += 1
        return true
    }
}
