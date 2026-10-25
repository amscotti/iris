import Foundation

@testable import IrisCore
@testable import IrisMacOS

/// In-memory pasteboard. Content is a full `ClipboardSnapshot` (items of
/// typed representations) so tests can cover non-text content and marker
/// types, not just strings.
final class FakeClipboard: ClipboardPort, @unchecked Sendable {
    static let plainTextType = "public.utf8-plain-text"
    static let concealedType = ClipboardSnapshot.concealedType

    private let lock = NSLock()
    private var content: ClipboardSnapshot
    private var revision = 0
    private(set) var clears = 0
    /// When false, writes report failure without touching storage.
    var setSucceeds = true
    /// Fail exactly this many upcoming writes, then succeed.
    var failNextSets = 0
    /// Optional hook invoked on every `string()` read (1-based count).
    var onRead: ((Int) -> Void)?
    /// When true, `snapshot()` reports content too large to capture.
    var snapshotFails = false
    /// When true, text reads simulate a busy bounded clipboard lease.
    var readUnavailable = false

    private var reads = 0

    init(string: String? = nil) {
        content = string.map { Self.text($0) } ?? ClipboardSnapshot()
    }

    init(snapshot: ClipboardSnapshot) {
        content = snapshot
    }

    /// One item holding `text` as plain text, plus empty marker types.
    static func text(_ text: String, markers: [String] = []) -> ClipboardSnapshot {
        let plain = ClipboardSnapshot.Representation(type: plainTextType, data: Data(text.utf8))
        return ClipboardSnapshot(items: [[plain] + markers.map { .init(type: $0, data: Data()) }])
    }

    var changeCount: Int { lock.withLock { revision } }

    /// Simulates an external writer touching the pasteboard without changing
    /// the string value (e.g. re-copying the same text).
    func bumpRevisionWithoutChangingContent() {
        lock.withLock { revision += 1 }
    }

    func string() -> String? {
        let count: Int = lock.withLock {
            reads += 1
            return reads
        }
        // Invoked outside the lock so the hook may itself write the clipboard.
        onRead?(count)
        return lock.withLock {
            content.items.lazy.flatMap { $0 }.first { $0.type == Self.plainTextType }
                .flatMap { String(data: $0.data, encoding: .utf8) }
        }
    }
    func readString() -> ClipboardTextRead {
        if lock.withLock({ readUnavailable }) { return .unavailable }
        if lock.withLock({ content.isConcealed }) { return .concealed }
        return string().map(ClipboardTextRead.text) ?? .empty
    }
    @discardableResult func setString(_ text: String) -> Bool {
        write(Self.text(text))
    }
    @discardableResult func setTransientString(_ text: String) -> Bool {
        write(Self.text(text, markers: [LiveClipboard.transientType]))
    }
    func clear() {
        lock.withLock {
            clears += 1
            content = ClipboardSnapshot()
            revision += 1
        }
    }
    func snapshot() -> ClipboardSnapshot? {
        lock.withLock {
            guard !snapshotFails else { return nil }
            return ClipboardSnapshot(items: content.items, revision: revision)
        }
    }
    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome {
        lock.withLock {
            if let previousRevision = previous?.revision, previousRevision != revision { return .changed }
            let backup = previous?.revision == revision ? previous : nil
            clearLocked()
            if writeLocked(Self.text(text, markers: [LiveClipboard.transientType])) {
                return .written(revision: revision, previous: backup)
            }
            if let backup { _ = writeLocked(backup) }
            return .failed
        }
    }
    @discardableResult func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        clear()
        return snapshot.isEmpty || write(snapshot)
    }
    @discardableResult func restoreIfUnchanged(
        _ snapshot: ClipboardSnapshot, dictation: String, revision: Int
    ) -> ClipboardRestoreOutcome {
        lock.withLock {
            let current = content.items.lazy.flatMap { $0 }.first { $0.type == Self.plainTextType }
                .flatMap { String(data: $0.data, encoding: .utf8) }
            guard current == dictation, revision == self.revision else { return .changed }
            clearLocked()
            if snapshot.isEmpty || writeLocked(snapshot) { return .restored }
            let preserved = writeLocked(Self.text(dictation, markers: [LiveClipboard.transientType]))
            return .failed(dictationPreserved: preserved)
        }
    }

    private func write(_ snapshot: ClipboardSnapshot) -> Bool {
        lock.withLock { writeLocked(snapshot) }
    }

    private func writeLocked(_ snapshot: ClipboardSnapshot) -> Bool {
        if failNextSets > 0 {
            failNextSets -= 1
            return false
        }
        guard setSucceeds else { return false }
        content = snapshot
        revision += 1
        return true
    }

    private func clearLocked() {
        clears += 1
        content = ClipboardSnapshot()
        revision += 1
    }
}

struct FakeFocus: FocusPort {
    var trusted: Bool
    var secure: Bool
    var target: InsertionTargetSnapshot?

    func isProcessTrusted() -> Bool { trusted }
    func focusedIsSecure() -> Bool { secure }
    func currentTarget() -> InsertionTarget? {
        guard let target else { return nil }
        return InsertionTarget(pid: target.pid, bundleID: target.bundleID)
    }
    func currentTargetSnapshot() -> InsertionTargetSnapshot? { target }
}

final class FakeKeys: KeyPostingPort, @unchecked Sendable {
    private let lock = NSLock()
    var canPostKeys = true
    /// Succeed exactly this many `postUnicodeString` calls, then report failure.
    var succeedUnicodePosts = Int.max
    private(set) var unicodePosts: [String] = []
    private(set) var pastePosts = 0
    var pasteSucceeds = true
    /// Invoked right after a paste posts, i.e. inside the restore window.
    /// Tests use it to simulate a user copy landing mid-restore.
    var onPaste: (() -> Void)?

    func canPost() -> Bool { lock.withLock { canPostKeys } }
    func postUnicodeString(_ chunk: String) -> Bool {
        lock.withLock {
            guard canPostKeys, succeedUnicodePosts > 0 else { return false }
            succeedUnicodePosts -= 1
            unicodePosts.append(chunk)
            return true
        }
    }
    func postPasteCommand() -> Bool {
        let succeeded = lock.withLock {
            pastePosts += 1
            return pasteSucceeds
        }
        // Outside the lock so the hook may touch other fakes.
        onPaste?()
        return succeeded
    }
}
