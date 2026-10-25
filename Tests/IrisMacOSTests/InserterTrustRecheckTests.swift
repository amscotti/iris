import Foundation
import IrisCore
import Testing

@testable import IrisMacOS

/// Focus whose Accessibility trust disappears after the entry check.
private final class TrustRevokingFocus: FocusPort, @unchecked Sendable {
    private let lock = NSLock()
    private var trustCalls = 0

    func isProcessTrusted() -> Bool {
        lock.withLock {
            trustCalls += 1
            return trustCalls == 1
        }
    }

    func focusedIsSecure() -> Bool { false }
    func currentTarget() -> InsertionTarget? { nil }
    func currentTargetSnapshot() -> InsertionTargetSnapshot? { nil }
}

@Test func trustRevokedMidTypingCopiesOnlyTheUntypedRemainder() {
    let clipboard = FakeClipboard()
    let keys = FakeKeys()
    let chunks = DictationTextProcessor.chunk(
        String(repeating: "b", count: DictationTextProcessor.maxChunkUTF16 * 2))
    #expect(chunks.count == 2)
    let inserter = AccessControlTextInserter(
        clipboard: clipboard, focus: TrustRevokingFocus(), keys: keys)
    var notices: [InsertionNotice] = []
    inserter.onNotice { notices.append($0) }
    inserter.insert(chunks.joined())
    #expect(keys.unicodePosts == [chunks[0]])
    #expect(clipboard.string() == chunks[1])
    #expect(notices == [.partialClipboard])
}

@Test func trustRevokedDuringPasteSnapshotFallsBackInsteadOfPasting() {
    let clipboard = FakeClipboard(string: "before")
    let keys = FakeKeys()
    let inserter = AccessControlTextInserter(
        method: .paste, clipboard: clipboard, focus: TrustRevokingFocus(), keys: keys,
        pasteRestoreSeconds: 0)
    var notices: [InsertionNotice] = []
    inserter.onNotice { notices.append($0) }
    inserter.insert("dictation")
    #expect(keys.pastePosts == 0)
    #expect(clipboard.string() == "dictation")
    #expect(notices == [.accessibilityOff])
}
