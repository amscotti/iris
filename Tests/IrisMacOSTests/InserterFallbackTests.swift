import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func pasteFailureKeepsDictationOnTheClipboard() {
    #expect(AccessControlTextInserter.pasteClipboardDisposition(didPost: false) == .keepDictation)
    #expect(AccessControlTextInserter.pasteClipboardDisposition(didPost: true) == .restorePrevious)
}

@Test func failedPastePostRetainsTheFullTranscriptWithoutRestoringPreviousClipboard() throws {
    let clipboard = FakeClipboard(string: "previous clipboard")
    let keys = FakeKeys()
    keys.pasteSucceeds = false
    let transcript = "The entire transcript, including café.\nA second line."
    var duringPost: ClipboardSnapshot?
    var postedRevision: Int?
    keys.onPaste = {
        duringPost = clipboard.snapshot()
        postedRevision = clipboard.changeCount
    }
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    var notices: [DictationNotice] = []
    inserter.onNotice { notices.append(.insertion($0)) }

    inserter.insert(transcript)

    #expect(keys.pastePosts == 1)
    #expect(keys.unicodePosts.isEmpty)
    #expect(duringPost == FakeClipboard.text(transcript, markers: [LiveClipboard.transientType]))
    #expect(clipboard.string() == transcript)
    #expect(clipboard.snapshot() == duringPost)
    // No restore or recovery write may follow a failed Cmd-V.
    let revision = try #require(postedRevision)
    #expect(clipboard.changeCount == revision)
    #expect(clipboard.clears == 1)
    #expect(notices == [.insertion(.pastePostFailed)])
    #expect(notices.map { NoticePresentation.message(for: $0) } == ["Couldn’t paste. The text is on the clipboard."])
}

@Test func blankInsertLeavesTheClipboardAlone() {
    let clipboard = FakeClipboard(string: "before")
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil), keys: FakeKeys())
    inserter.update(method: .paste)
    inserter.onNotice(nil)
    inserter.insert("")
    inserter.insert("   ")
    #expect(clipboard.string() == "before")
    #expect(clipboard.clears == 0)
}

@Test func untrustedInsertCopiesToClipboardWithNotice() {
    let clipboard = FakeClipboard()
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: false, secure: false, target: nil), keys: FakeKeys())
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("hello")
    #expect(clipboard.string() == "hello")
    // The fallback copy is transient: clipboard managers must not archive it.
    #expect(clipboard.snapshot()?.items.first?.contains { $0.type == LiveClipboard.transientType } == true)
    #expect(notices == ["Accessibility access is off. Text was copied to the clipboard instead."])
}

@Test func secureFieldFallsBackToClipboard() {
    let clipboard = FakeClipboard()
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: true, secure: true, target: nil), keys: FakeKeys())
    inserter.insert("hello")
    #expect(clipboard.string() == "hello")
}

@Test func changedFocusStillInsertsIntoFocusedApp() {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: InsertionTargetSnapshot(pid: 2)),
        keys: keys)
    inserter.insert("hello", target: InsertionTargetSnapshot(pid: 1))
    #expect(clipboard.string() == nil)
    #expect(keys.unicodePosts.joined() == "hello")
}

@Test func keyPostFailureFallsBackToClipboard() {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    keys.canPostKeys = false
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys)
    inserter.insert("hello")
    #expect(clipboard.string() == "hello")
    #expect(clipboard.snapshot()?.items.first?.contains { $0.type == LiveClipboard.transientType } == true)
}

@Test func pasteRestoreSkipsWhenClipboardChangedDuringWindow() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    keys.onPaste = { _ = clipboard.setString("user copy") }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 1)
    #expect(clipboard.string() == "user copy")
}

@Test func pasteRestoreReturnsPreviousClipboardWhenUnchanged() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    inserter.insert("dictation")
    #expect(keys.pastePosts == 1)
    #expect(clipboard.string() == "before")
}

@Test func pasteRestoreKeepsDictationWhenTheClipboardWasEmpty() {
    // Nothing to restore: the dictation stays instead of clearing to nothing.
    let clipboard = FakeClipboard(string: nil)
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    inserter.insert("dictation")
    #expect(keys.pastePosts == 1)
    #expect(clipboard.string() == "dictation")
}

@Test func pasteRestorePutsBackNonTextClipboardContent() {
    // An image-only clipboard's full snapshot must come back intact.
    let image = ClipboardSnapshot(items: [[.init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]])
    let clipboard = FakeClipboard(snapshot: image)
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    inserter.insert("dictation")
    #expect(keys.pastePosts == 1)
    #expect(clipboard.snapshot() == image)
}

@Test func pasteDropsPasswordManagerSecretsInsteadOfRestoringThem() {
    // Restoring a concealed secret would re-expose it to clipboard history.
    let secret = FakeClipboard.text("hunter2", markers: [FakeClipboard.concealedType])
    let clipboard = FakeClipboard(snapshot: secret)
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: FakeKeys(), pasteRestoreSeconds: 0)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("dictation")
    #expect(clipboard.string() == "dictation")
    #expect(clipboard.snapshot()?.isConcealed == false)
    #expect(
        notices == [
            "Your words were already pasted. A copied password wasn’t restored for privacy; "
                + "the transcript remains on the clipboard."
        ])
}

@Test func pasteSkipsRestoreAndSaysSoWhenTheClipboardIsTooLarge() {
    let clipboard = FakeClipboard(string: "huge")
    clipboard.snapshotFails = true
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 1)
    #expect(clipboard.string() == "dictation")
    #expect(
        notices == [
            "Your words were already pasted. The previous clipboard couldn’t be kept; "
                + "the transcript remains on the clipboard."
        ])
}

@Test func pasteModeMarksTheTemporaryCopyTransient() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    var duringPaste: ClipboardSnapshot?
    keys.onPaste = { duringPaste = clipboard.snapshot() }
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    inserter.insert("dictation")
    #expect(duringPaste == FakeClipboard.text("dictation", markers: [LiveClipboard.transientType]))
    #expect(clipboard.string() == "before")
}

@Test func concealedClipboardSurvivesAFailedPasteWrite() {
    // A failed write must not destroy the copied secret.
    let secret = FakeClipboard.text("hunter2", markers: [FakeClipboard.concealedType])
    let clipboard = FakeClipboard(snapshot: secret)
    clipboard.failNextSets = 1
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: FakeKeys(), pasteRestoreSeconds: 0)
    inserter.insert("dictation")
    #expect(clipboard.snapshot() == secret)
}

@Test func liveClipboardSnapshotRoundTripsEveryTypeOnAPrivatePasteboard() {
    // Real AppKit behavior on a uniquely named pasteboard.
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let clipboard = LiveClipboard(name: name)
    let concealed = NSPasteboard.PasteboardType(FakeClipboard.concealedType)
    let secret = NSPasteboardItem()
    secret.setString("hunter2", forType: .string)
    secret.setData(Data(), forType: concealed)
    let image = NSPasteboardItem()
    image.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([secret, image]))

    guard let saved = clipboard.snapshot() else {
        Issue.record("snapshot unexpectedly exceeded its budget")
        return
    }
    clipboard.clear()
    #expect(clipboard.setTransientString("dictation"))
    #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType(LiveClipboard.transientType)) == true)
    #expect(clipboard.restore(saved))
    #expect(clipboard.snapshot() == saved)
    #expect(pasteboard.pasteboardItems?.count == 2)
    #expect(pasteboard.pasteboardItems?.first?.types.contains(concealed) == true)
    #expect(pasteboard.pasteboardItems?.last?.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]))
}

@Test func clipboardFallbackReportsHonestFailureWhenCopyFails() {
    let clipboard = FakeClipboard()
    clipboard.setSucceeds = false
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: false, secure: false, target: nil), keys: FakeKeys())
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("hello")
    #expect(clipboard.string() == nil)
    #expect(notices == ["Could not copy the transcript to the clipboard."])
}

@Test func pasteWriteFailureRestoresPreviousClipboard() {
    let clipboard = FakeClipboard(string: "before")
    clipboard.failNextSets = 1
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: FakeKeys(), pasteRestoreSeconds: 0)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("dictation")
    #expect(clipboard.string() == "before")
    #expect(notices == ["Could not place text on the clipboard."])
}

@Test func partialChunkFailureCopiesOnlyTheUntypedRemainder() {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    keys.succeedUnicodePosts = 1
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    let text = String(repeating: "a", count: DictationTextProcessor.maxChunkUTF16 + 500)
    #expect(text.utf16.count > DictationTextProcessor.maxChunkUTF16)
    inserter.insert(text)
    // Only the untyped remainder is copied (the typed prefix cannot be untyped).
    #expect(keys.unicodePosts.count == 1)
    #expect(clipboard.string() == String(text.dropFirst(DictationTextProcessor.maxChunkUTF16)))
    #expect(clipboard.snapshot()?.items.first?.contains { $0.type == LiveClipboard.transientType } == true)
    #expect(notices == ["Only the untyped part was copied to the clipboard. The already-typed prefix was not copied."])
}

/// Focus that flips to a secure field after N `focusedIsSecure()` calls.
private final class SecuringFocus: FocusPort, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let secureAfter: Int
    init(secureAfter: Int) { self.secureAfter = secureAfter }
    func isProcessTrusted() -> Bool { true }
    func focusedIsSecure() -> Bool {
        lock.withLock {
            calls += 1
            return calls > secureAfter
        }
    }
    func currentTarget() -> InsertionTarget? { nil }
    func currentTargetSnapshot() -> InsertionTargetSnapshot? { nil }
}

@Test func secureFieldMidInsertRoutesTheRemainderThroughTheConcealedClipboard() {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    let chunks = DictationTextProcessor.chunk(
        String(repeating: "b", count: DictationTextProcessor.maxChunkUTF16 * 3))
    #expect(chunks.count >= 3)
    // Secure after the entry check: recheck concealed-copies only the remainder.
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: SecuringFocus(secureAfter: 1), keys: keys)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert(chunks.joined())
    #expect(keys.unicodePosts == [chunks[0]])
    let remainder = chunks.dropFirst(1).joined()
    #expect(clipboard.string() == remainder)
    #expect(clipboard.snapshot()?.isConcealed == true)
    #expect(clipboard.snapshot()?.items.first?.contains { $0.type == LiveClipboard.transientType } != true)
    #expect(notices == ["Only the untyped part was copied to the clipboard. The already-typed prefix was not copied."])
}

@Test func pasteRechecksSecureAfterSnapshotAndConcealsInsteadOfPasting() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    // Secure during the snapshot window: the recheck must refuse the paste.
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard, focus: SecuringFocus(secureAfter: 1), keys: keys,
        pasteRestoreSeconds: 0)
    var notices: [InsertionNotice] = []
    inserter.onNotice { notices.append($0) }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 0)
    #expect(clipboard.string() == "dictation")
    #expect(clipboard.snapshot()?.isConcealed == true)
    #expect(notices == [.secureField])
}

@Test func secureDispositionRecognizesSubroleRoleAndSecureInput() {
    #expect(
        AccessControlTextInserter.secureDisposition(
            subrole: "AXSecureTextField", role: "AXTextField", secureInputEnabled: false))
    #expect(
        AccessControlTextInserter.secureDisposition(
            subrole: "AXTextField", role: "AXSecureTextField", secureInputEnabled: false))
    #expect(
        !AccessControlTextInserter.secureDisposition(
            subrole: "AXTextField", role: "AXTextField", secureInputEnabled: false))
    #expect(!AccessControlTextInserter.secureDisposition(subrole: nil, role: nil, secureInputEnabled: false))
    // System-wide Secure Event Input refuses regardless of the focused field.
    #expect(
        AccessControlTextInserter.secureDisposition(
            subrole: nil, role: nil, secureInputEnabled: true))
}

@Test func pasteRestoreSkipsWhenRevisionChangedButTextIsTheSame() {
    // A revision bump with identical text must still skip the restore.
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    keys.onPaste = { clipboard.bumpRevisionWithoutChangingContent() }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 1)
    #expect(clipboard.string() == "dictation")
}

@Test func typedChunksCarryNoModifierFlags() throws {
    // Built, never posted: chunk events must clear modifier flags.
    let source = CGEventSource(stateID: .privateState)
    let (down, keyUp) = try #require(LiveKeyPosting.unicodeKeyEvents("héllo", source: source))
    #expect(down.flags.isEmpty)
    #expect(keyUp.flags.isEmpty)
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
    #expect(String(utf16CodeUnits: buffer, count: length) == "héllo")
}

@Test func secureInputRefusesOnlyWhenTheFocusedAppHoldsItOrIsUnknown() {
    #expect(AccessControlTextInserter.secureInputBlocksInsertion(holderPID: 42, focusedPID: 42))
    #expect(!AccessControlTextInserter.secureInputBlocksInsertion(holderPID: 42, focusedPID: 7))
    #expect(AccessControlTextInserter.secureInputBlocksInsertion(holderPID: nil, focusedPID: 7))
    #expect(AccessControlTextInserter.secureInputBlocksInsertion(holderPID: 42, focusedPID: nil))
}

@Test func secureFieldFallbackIsConcealedFromClipboardHistory() {
    let clipboard = FakeClipboard()
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: FakeFocus(trusted: true, secure: true, target: nil), keys: FakeKeys())
    inserter.insert("hunter2")
    #expect(clipboard.string() == "hunter2")
    #expect(clipboard.snapshot()?.isConcealed == true)
}
