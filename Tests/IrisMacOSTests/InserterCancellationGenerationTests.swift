import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

/// Blocks the second secure-field query, after the first keystroke chunk has
/// posted and the worker has slept. Releasing it models a late AX return.
private final class P1LateFocus: FocusPort, @unchecked Sendable {
    private let lock = NSLock()
    private var secureCalls = 0
    private let entered = AsyncStream.makeStream(of: Void.self)
    let release = DispatchSemaphore(value: 0)

    func isProcessTrusted() -> Bool { true }

    func focusedIsSecure() -> Bool {
        let call = lock.withLock {
            secureCalls += 1
            return secureCalls
        }
        guard call == 2 else { return false }
        entered.continuation.yield(())
        _ = release.wait(timeout: .now() + 10)
        return false
    }

    func currentTarget() -> InsertionTarget? { nil }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Test func cancelledLateAXReturnCannotPostTheNextChunk() async throws {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    let focus = P1LateFocus()
    defer { focus.release.signal() }
    let inserter = AccessControlTextInserter(clipboard: clipboard, focus: focus, keys: keys)
    let text = String(repeating: "x", count: DictationTextProcessor.maxChunkUTF16 * 2)
    let chunks = DictationTextProcessor.chunk(text)
    #expect(chunks.count == 2)

    let worker = Task { inserter.insert(text) }
    try await AsyncDeadline.run(seconds: 5) { await focus.waitUntilEntered() }
    #expect(keys.unicodePosts == [chunks[0]])
    inserter.cancelInsertion()
    focus.release.signal()
    try await AsyncDeadline.run(seconds: 5) { await worker.value }

    #expect(keys.unicodePosts == [chunks[0]])
    #expect(clipboard.string() == nil)
}

/// The paste transaction may finish after cancellation, but its return must
/// not authorize the final Cmd-V into whatever app has since taken focus.
private final class P1LatePasteboard: ClipboardPort, @unchecked Sendable {
    private let base = FakeClipboard(string: "before")
    private let entered = AsyncStream.makeStream(of: Void.self)
    let release = DispatchSemaphore(value: 0)

    var changeCount: Int { base.changeCount }
    func string() -> String? { base.string() }
    func readString() -> ClipboardTextRead { base.readString() }
    func setString(_ text: String) -> Bool { base.setString(text) }
    func setTransientString(_ text: String) -> Bool { base.setTransientString(text) }
    func clear() { base.clear() }
    func snapshot() -> ClipboardSnapshot? { base.snapshot() }
    func restore(_ snapshot: ClipboardSnapshot) -> Bool { base.restore(snapshot) }
    func restoreIfUnchanged(
        _ snapshot: ClipboardSnapshot, dictation: String, revision: Int
    ) -> ClipboardRestoreOutcome {
        base.restoreIfUnchanged(snapshot, dictation: dictation, revision: revision)
    }

    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        entered.continuation.yield(())
        _ = release.wait(timeout: .now() + 10)
        return base.preparePaste(text, previous: previous)
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Test func cancelledPasteboardReturnCannotPostLatePasteCommand() async throws {
    let clipboard = P1LatePasteboard()
    let keys = FakeKeys()
    defer { clipboard.release.signal() }
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard,
        focus: FakeFocus(trusted: true, secure: false, target: nil), keys: keys,
        pasteRestoreSeconds: 0)

    let worker = Task { inserter.insert("late words") }
    try await AsyncDeadline.run(seconds: 5) { await clipboard.waitUntilEntered() }
    inserter.cancelInsertion()
    clipboard.release.signal()
    try await AsyncDeadline.run(seconds: 5) { await worker.value }

    #expect(keys.pastePosts == 0)
    #expect(keys.unicodePosts.isEmpty)
}
