import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private enum ClipboardFailurePoint: Sendable { case writing, restoring }

/// An external copy owns the production gate until the tested acquisition
/// times out, then frees it before the inserter can attempt any late recovery.
private final class ClipboardWriterHold: @unchecked Sendable {
    let name: NSPasteboard.Name
    let access: ClipboardAccess
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    private var joined = false

    init(name: NSPasteboard.Name, access: ClipboardAccess) {
        self.name = name
        self.access = access
    }

    func begin() {
        lock.withLock { started = true }
        Thread {
            self.access.withAccess(or: ()) {
                let pasteboard = NSPasteboard(name: self.name)
                pasteboard.clearContents()
                pasteboard.setString("user copy", forType: .string)
                self.entered.signal()
                self.released.wait()
            }
            self.finished.signal()
        }.start()
        #expect(entered.wait(timeout: .now() + 5) == .success)
    }

    func releaseAndJoin() {
        let needed = lock.withLock {
            guard started, !joined else { return false }
            joined = true
            return true
        }
        guard needed else { return }
        released.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }
}

private struct RecoveringAccessClipboard: ClipboardPort {
    let live: LiveClipboard
    let hold: ClipboardWriterHold
    let failure: ClipboardFailurePoint
    func string() -> String? { live.string() }
    func setString(_ text: String) -> Bool { live.setString(text) }
    func setTransientString(_ text: String) -> Bool { live.setTransientString(text) }
    func clear() { live.clear() }
    func snapshot() -> ClipboardSnapshot? { live.snapshot() }
    func restore(_ snapshot: ClipboardSnapshot) -> Bool { live.restore(snapshot) }
    var changeCount: Int { live.changeCount }

    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        guard failure == .writing else { return live.preparePaste(text, previous: previous) }
        hold.begin()
        let result = live.preparePaste(text, previous: previous)
        #expect(result == .unavailable)
        hold.releaseAndJoin()
        return result
    }

    func restoreIfUnchanged(_ snapshot: ClipboardSnapshot, dictation: String, revision: Int)
        -> ClipboardRestoreOutcome
    {
        guard failure == .restoring else {
            return live.restoreIfUnchanged(snapshot, dictation: dictation, revision: revision)
        }
        hold.begin()
        let result = live.restoreIfUnchanged(snapshot, dictation: dictation, revision: revision)
        #expect(result == .unavailable)
        hold.releaseAndJoin()
        return result
    }
}

@Test(arguments: [ClipboardFailurePoint.writing, .restoring])
private func clipboardTimeoutRecoveryCannotOverwriteANewerCopy(failure: ClipboardFailurePoint) {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let access = ClipboardAccess(waitSeconds: 0.02)
    let live = LiveClipboard(name: name, access: access)
    #expect(live.setString("old clipboard"))
    let hold = ClipboardWriterHold(name: name, access: access)
    defer {
        hold.releaseAndJoin()
        NSPasteboard(name: name).releaseGlobally()
    }
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: RecoveringAccessClipboard(live: live, hold: hold, failure: failure),
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys, pasteRestoreSeconds: 0)
    var notices: [String] = []
    var reasons: [InsertionNotice] = []
    inserter.onNotice {
        reasons.append($0)
        notices.append(NoticePresentation.message(for: .insertion($0)))
    }
    inserter.insert("dictation")
    #expect(live.string() == "user copy")
    #expect(keys.pastePosts == (failure == .writing ? 0 : 1))
    #expect(reasons == [failure == .writing ? .clipboardWriteFailed : .restoreAccessUnavailable])
    // An unavailable lease cannot prove the transcript is still on the clipboard.
    #expect(reasons.map(\.category) == [.problem])
    let expected =
        failure == .writing
        ? "Could not place text on the clipboard."
        : "Your words were already pasted. Clipboard access was unavailable, so the previous contents weren’t restored."
    #expect(notices == [expected])
}

@Test func aSnapshotThatBecameStaleCannotReplaceANewerClipboardCopy() throws {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let live = LiveClipboard(name: name)
    defer { NSPasteboard(name: name).releaseGlobally() }
    #expect(live.setString("old clipboard"))
    let previous = try #require(live.snapshot())
    #expect(live.setString("user copy"))
    #expect(live.preparePaste("dictation", previous: previous) == .changed)
    #expect(live.string() == "user copy")
}

/// Captures the old revision, then simulates an external copy before returning it.
/// The inserter's snapshot worker completes before preparePaste runs: no timing race.
private struct CopyAfterSnapshotClipboard: ClipboardPort {
    let storage = FakeClipboard(string: "old clipboard")
    func string() -> String? { storage.string() }
    func setString(_ text: String) -> Bool { storage.setString(text) }
    func setTransientString(_ text: String) -> Bool { storage.setTransientString(text) }
    func clear() { storage.clear() }
    func snapshot() -> ClipboardSnapshot? {
        let previous = storage.snapshot()
        _ = storage.setString("user copy")
        return previous
    }
    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        storage.preparePaste(text, previous: previous)
    }
    func restore(_ snapshot: ClipboardSnapshot) -> Bool { storage.restore(snapshot) }
    func restoreIfUnchanged(_ snapshot: ClipboardSnapshot, dictation: String, revision: Int)
        -> ClipboardRestoreOutcome
    {
        storage.restoreIfUnchanged(snapshot, dictation: dictation, revision: revision)
    }
    var changeCount: Int { storage.changeCount }
}

@Test func aCopyAfterSnapshotSkipsPasteAndReportsTheTypedReason() {
    let clipboard = CopyAfterSnapshotClipboard()
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil),
        keys: keys, pasteRestoreSeconds: 0)
    var notices: [InsertionNotice] = []
    inserter.onNotice { notices.append($0) }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 0)
    #expect(keys.unicodePosts.isEmpty)
    #expect(clipboard.storage.string() == "user copy")
    #expect(clipboard.storage.clears == 0)
    #expect(notices == [.clipboardChangedBeforePaste])
}

@Test func anOwnedRestoreFailureReportsIfItsAtomicRecoveryAlsoFailed() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    keys.onPaste = { clipboard.failNextSets = 2 }
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard, focus: FakeFocus(trusted: true, secure: false, target: nil),
        keys: keys, pasteRestoreSeconds: 0)
    var notices: [String] = []
    inserter.onNotice { notices.append(NoticePresentation.message(for: .insertion($0))) }
    inserter.insert("dictation")
    #expect(clipboard.string() == nil)
    #expect(notices == ["Your words were pasted; the previous clipboard couldn’t be restored or kept."])
}

@Test func restoreIfUnchangedReportsEachOutcome() {
    // Check the in-memory port's contract, including simulated write failure.
    // ClipboardRestoreTests exercises LiveClipboard's actual restore decisions.
    let snapshot = FakeClipboard.text("before")

    let clean = FakeClipboard(string: "dictation")
    #expect(
        clean.restoreIfUnchanged(snapshot, dictation: "dictation", revision: clean.changeCount) == .restored)
    #expect(clean.string() == "before")

    let copiedOver = FakeClipboard(string: "dictation")
    let staleRevision = copiedOver.changeCount
    _ = copiedOver.setString("user copy")
    #expect(copiedOver.restoreIfUnchanged(snapshot, dictation: "dictation", revision: staleRevision) == .changed)
    #expect(copiedOver.string() == "user copy")

    let failing = FakeClipboard(string: "dictation")
    failing.failNextSets = 1
    #expect(
        failing.restoreIfUnchanged(snapshot, dictation: "dictation", revision: failing.changeCount)
            == .failed(dictationPreserved: true))
}

private final class TextWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    var enabled: Bool {
        get { lock.withLock { fail } }
        set { lock.withLock { fail = newValue } }
    }
}

@Test func pasteWithoutASnapshotRestoresTheTextFallbackWhenTheWriteFails() throws {
    // The snapshot budget gave up (e.g. a huge clipboard), then the write
    // failed: the transcript is lost, but the user's text must not vanish
    // with it.
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.setString("user text", forType: .string))
    let faults = TextWriteFault()
    faults.enabled = true
    let live = LiveClipboard(name: name, access: ClipboardAccess(), failTextWrites: { faults.enabled })
    #expect(live.preparePaste("dictation", previous: nil) == .failed)
    #expect(pasteboard.string(forType: .string) == "user text")
    #expect(pasteboard.pasteboardItems?.count == 1)
    // The fallback restored, the next paste attempt proceeds normally.
    faults.enabled = false
    let outcome = live.preparePaste("dictation", previous: nil)
    #expect(outcome == .written(revision: Int(pasteboard.changeCount), previous: nil))
    #expect(pasteboard.string(forType: .string) == "dictation")
}

@Test func pasteRefusesToClearContentItCannotRestoreWithoutASnapshot() throws {
    // Image-only clipboard, no snapshot (budget gave up), no text fallback:
    // the destructive clear is refused and the clipboard stays intact.
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    pasteboard.clearContents()
    let image = NSPasteboardItem()
    #expect(image.setData(png, forType: .png))
    #expect(pasteboard.writeObjects([image]))
    let revision = Int(pasteboard.changeCount)
    let live = LiveClipboard(name: name, access: ClipboardAccess())
    #expect(live.preparePaste("dictation", previous: nil) == .failed)
    #expect(Int(pasteboard.changeCount) == revision)
    #expect(pasteboard.data(forType: .png) == png)
    #expect(pasteboard.string(forType: .string) == nil)
}

@Test func pasteWithoutASnapshotProceedsOnAnEmptyClipboard() {
    // An empty clipboard has nothing to destroy: no refusal, and a failed
    // write leaves it as empty as it started.
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    let live = LiveClipboard(name: name, access: ClipboardAccess(), failTextWrites: { true })
    #expect(live.preparePaste("dictation", previous: nil) == .failed)
    #expect(pasteboard.pasteboardItems?.isEmpty == true)
}

@Test func liveClipboardSnapshotGivesUpPastItsByteBudget() {
    let name = NSPasteboard.Name("iris-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setData(Data(repeating: 1, count: 64), forType: .png)
    #expect(LiveClipboard(name: name, byteBudget: 16).snapshot() == nil)
    #expect(LiveClipboard(name: name, byteBudget: 1024).snapshot()?.isEmpty == false)
}
