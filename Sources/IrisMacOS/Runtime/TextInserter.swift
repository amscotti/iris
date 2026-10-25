import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IrisCore
import os

/// Inserts finalized dictation at the cursor of the frontmost app.
///
/// Keystroke path posts real Unicode key events system-wide to the HID tap
/// (combined session source, key down plus key up), which is what reaches
/// other apps; a session-local tap would only observe our own events. Long
/// text splits into small platform-safe chunks (see
/// `DictationTextProcessor.maxChunkUTF16`) with a short pause between them.
/// Paste is the fallback mechanism.
///
/// Insertion is refused into secure fields, while system-wide Secure Event
/// Input is active, and without the Accessibility grant; all fall back to
/// the clipboard with a notice for the pill.
///
/// Pacing uses blocking sleeps (between keystroke chunks, the paste restore
/// window). Callers must run insertion off the orchestrator actor (blocking
/// worker) so cancellation and cleanup deadlines stay responsive; see
/// `DictationOrchestrator.insertPrepared`.
public final class AccessControlTextInserter: ConfigurableTextInserting, @unchecked Sendable {
    /// `AXSecureTextField` is a *subrole*: standard secure fields (AppKit
    /// `NSSecureTextField`, WebKit password fields) report role
    /// `AXTextField` with this subrole. The same string is compared against
    /// the role as a fallback for nonstandard apps.
    static let secureFieldType = "AXSecureTextField"
    private static let interChunkSeconds: TimeInterval = 0.005
    /// How long the transcript stays on the clipboard before the previous
    /// content returns. A busy target app reads the pasteboard late;
    /// restoring too early would paste the old clipboard instead of the
    /// transcript. There is no AppKit signal for "the paste was consumed",
    /// so this is a fixed window: long enough for slow apps, short enough
    /// that the next take is not blocked for long.
    public static let defaultPasteRestoreSeconds: TimeInterval = 1.0

    enum PasteClipboardDisposition: Equatable {
        case restorePrevious
        case keepDictation
    }

    private let lock = NSLock()
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "insertion")
    private var method: AppSettings.InsertMethod
    /// Incremented for each new insertion and by deadline cancellation. Every
    /// delayed side effect carries the generation that authorized it.
    private var insertionGeneration = 0
    private var noticeHandler: ((InsertionNotice) -> Void)?
    private let clipboard: any ClipboardPort
    private let focus: any FocusPort
    private let keys: any KeyPostingPort
    private let pasteRestoreSeconds: TimeInterval

    public init(
        method: AppSettings.InsertMethod = .keystroke,
        clipboard: any ClipboardPort,
        focus: any FocusPort,
        keys: any KeyPostingPort,
        pasteRestoreSeconds: TimeInterval = AccessControlTextInserter.defaultPasteRestoreSeconds
    ) {
        self.method = method
        self.clipboard = clipboard
        self.focus = focus
        self.keys = keys
        self.pasteRestoreSeconds = pasteRestoreSeconds
    }

    /// Current insertion mechanism. Updated live from settings.
    public func update(method: AppSettings.InsertMethod) {
        lock.withLock { self.method = method }
    }

    /// Called on fallback paths with a stable reason for presentation.
    /// Invoked from the inserting thread.
    public func onNotice(_ handler: ((InsertionNotice) -> Void)?) {
        lock.withLock { noticeHandler = handler }
    }

    public func insert(_ text: String) {
        insert(text, target: nil)
    }

    public func insert(_ text: String, target: InsertionTargetSnapshot?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = beginInsertion()
        let trusted = focus.isProcessTrusted()
        guard isInsertionCurrent(generation) else { return }
        guard trusted else {
            logger.notice("Insertion fell back to the clipboard: Accessibility trust is off.")
            clipboardFallback(
                text, successNotice: .accessibilityOff, generation: generation)
            return
        }
        if let target {
            let snapshot = focus.currentTargetSnapshot()
            guard isInsertionCurrent(generation) else { return }
            if let snapshot, snapshot.pid != target.pid {
                logger.info("Insertion target changed since press start; inserting into the focused app.")
            }
        }
        let secure = focus.focusedIsSecure()
        guard isInsertionCurrent(generation) else { return }
        if secure {
            logger.notice("Insertion fell back to the clipboard: focused field is secure.")
            // Text meant for a password field is marked concealed so clipboard
            // history managers do not record it.
            clipboardFallback(
                text, successNotice: .secureField,
                concealed: true, generation: generation)
            return
        }
        switch currentMethod() {
        case .keystroke: typeText(text, generation: generation)
        case .paste: pasteText(text, generation: generation)
        }
    }

    /// Deadline cancellation invalidates the worker; it does not interrupt a
    /// healthy insertion during ordinary stop, which is joined by its owner.
    public func cancelInsertion() {
        lock.withLock { insertionGeneration += 1 }
    }

    // MARK: - Private

    private func beginInsertion() -> Int {
        lock.withLock {
            insertionGeneration += 1
            return insertionGeneration
        }
    }

    private func isInsertionCurrent(_ generation: Int) -> Bool {
        lock.withLock { insertionGeneration == generation }
    }

    private func currentMethod() -> AppSettings.InsertMethod {
        lock.withLock { method }
    }

    private func notify(_ notice: InsertionNotice) {
        let handler = lock.withLock { noticeHandler }
        handler?(notice)
    }

    /// Rechecks trust and secure focus between chunks. False covers both a
    /// cancelled generation and a fallback that has already been reported.
    private func recheckChunk(_ chunks: [String], at index: Int, generation: Int) -> Bool {
        guard isInsertionCurrent(generation) else { return false }
        Thread.sleep(forTimeInterval: Self.interChunkSeconds)
        guard isInsertionCurrent(generation) else { return false }
        let trusted = focus.isProcessTrusted()
        guard isInsertionCurrent(generation) else { return false }
        guard trusted else {
            logger.notice("Insertion fell back to the clipboard: Accessibility trust was revoked mid-insert.")
            clipboardFallback(
                Self.untypedRemainder(chunks, from: index), successNotice: .partialClipboard,
                generation: generation)
            return false
        }
        let secure = focus.focusedIsSecure()
        guard isInsertionCurrent(generation) else { return false }
        guard !secure else {
            logger.notice("Insertion fell back to the clipboard: the field turned secure mid-insert.")
            clipboardFallback(
                Self.untypedRemainder(chunks, from: index), successNotice: .partialClipboard,
                concealed: true, generation: generation)
            return false
        }
        return isInsertionCurrent(generation)
    }

    private func typeText(_ text: String, generation: Int) {
        guard isInsertionCurrent(generation) else { return }
        let canPost = keys.canPost()
        guard isInsertionCurrent(generation) else { return }
        guard canPost else {
            logger.error("Keystroke insertion unavailable: no event source; used the clipboard.")
            clipboardFallback(
                text, successNotice: .keystrokesUnavailable, generation: generation)
            return
        }
        let chunks = DictationTextProcessor.chunk(text)
        for (index, chunk) in chunks.enumerated() {
            if index > 0, !recheckChunk(chunks, at: index, generation: generation) { return }
            // Check immediately before every post as well as after each sleep
            // and AX query: cancellation may have landed on the blocking worker.
            guard isInsertionCurrent(generation) else { return }
            if !keys.postUnicodeString(chunk) {
                // The typed prefix is already in the document and cannot be
                // untyped; only the untyped remainder is copied so pasting it
                // cannot duplicate the prefix.
                logger.error("Keystroke insertion failed mid-text; the remainder was copied to the clipboard.")
                clipboardFallback(
                    Self.untypedRemainder(chunks, from: index),
                    successNotice: index == 0 ? .keystrokesUnavailable : .partialClipboard,
                    generation: generation)
                return
            }
        }
    }

    /// Reads the clipboard with a hard overall bound. The snapshot itself
    /// checks its budget between reads, but one slow promised type can block
    /// a single read indefinitely; abandon it instead of stalling insertion
    /// past its deadline. The abandoned read finishes on its own thread.
    /// Callers must already be off the orchestrator actor (blocking worker).
    private func snapshotWithinBudget() -> ClipboardSnapshot? {
        final class Box: @unchecked Sendable { var value: ClipboardSnapshot?? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            box.value = self.clipboard.snapshot()
            done.signal()
        }
        worker.qualityOfService = .userInitiated
        worker.start()
        // Margin over the soft budget: a read that starts inside the budget
        // may finish just past it, and that snapshot is still usable.
        guard done.wait(timeout: .now() + LiveClipboard.snapshotSecondsBudget + 0.5) == .success else {
            return nil
        }
        return box.value ?? nil
    }

    /// Performs the blocking pasteboard/focus preflight. The outer optional
    /// distinguishes an aborted generation/fallback from a usable nil snapshot.
    private func pasteSnapshotIfAllowed(_ text: String, generation: Int) -> ClipboardSnapshot?? {
        guard isInsertionCurrent(generation) else { return nil }
        let snapshot = snapshotWithinBudget()
        guard isInsertionCurrent(generation) else { return nil }
        let trusted = focus.isProcessTrusted()
        guard isInsertionCurrent(generation) else { return nil }
        guard trusted else {
            logger.notice("Paste fell back to the clipboard: Accessibility trust was revoked during snapshot.")
            clipboardFallback(text, successNotice: .accessibilityOff, generation: generation)
            return nil
        }
        let secure = focus.focusedIsSecure()
        guard isInsertionCurrent(generation) else { return nil }
        guard !secure else {
            logger.notice("Paste fell back to the clipboard: the field turned secure during snapshot.")
            clipboardFallback(text, successNotice: .secureField, concealed: true, generation: generation)
            return nil
        }
        return snapshot
    }

    private func preparePasteForInsertion(
        _ text: String, previous: ClipboardSnapshot?, generation: Int
    ) -> (revision: Int, saved: ClipboardSnapshot?)? {
        let preparation = clipboard.preparePaste(text, previous: previous)
        // A pasteboard call may return after the deadline. Its transaction has
        // already settled, but it must not authorize a delayed Cmd-V.
        guard isInsertionCurrent(generation) else { return nil }
        switch preparation {
        case .written(let revision, let saved): return (revision, saved)
        case .changed:
            notify(.clipboardChangedBeforePaste)
        case .unavailable, .failed:
            // Mutation and any safe rollback belong to the port's transaction;
            // a later retry here could overwrite a copy made after a timeout.
            logger.error("Paste insertion failed: could not write dictation to the clipboard.")
            notify(.clipboardWriteFailed)
        }
        return nil
    }

    private func pasteText(_ text: String, generation: Int) {
        guard let snapshot = pasteSnapshotIfAllowed(text, generation: generation),
            let preparation = preparePasteForInsertion(text, previous: snapshot, generation: generation)
        else { return }
        guard preparation.revision >= 0 else {
            // Alternative ports may return an invalid/unreadable revision.
            // Never post Cmd-V without a positively owned clipboard write.
            notify(.clipboardRevisionUnavailable)
            return
        }
        guard isInsertionCurrent(generation) else { return }
        let posted = keys.postPasteCommand()
        guard isInsertionCurrent(generation) else { return }
        switch Self.pasteClipboardDisposition(didPost: posted) {
        case .keepDictation:
            notify(.pastePostFailed)
        case .restorePrevious:
            guard let saved = preparation.saved else {
                logger.notice("Paste restore skipped: the previous clipboard could not be kept.")
                notify(.previousClipboardUnavailable)
                return
            }
            restorePreviousClipboard(
                saved, text: text, writtenRevision: preparation.revision, generation: generation)
        }
    }

    /// Puts the pre-paste clipboard back when nothing changed in the
    /// meantime. A password manager's secret is dropped rather than restored:
    /// putting it back would re-expose it to clipboard history and to a slow
    /// app that reads the pasteboard after the restore.
    private func restorePreviousClipboard(
        _ saved: ClipboardSnapshot, text: String, writtenRevision: Int, generation: Int
    ) {
        guard isInsertionCurrent(generation) else { return }
        guard !saved.isConcealed else {
            logger.info("Paste restore skipped: the previous clipboard held a concealed secret.")
            notify(.concealedClipboardNotRestored)
            return
        }
        Thread.sleep(forTimeInterval: pasteRestoreSeconds)
        guard isInsertionCurrent(generation) else { return }
        if saved.isEmpty {
            // The clipboard was empty before; keep the dictation available
            // instead of clearing it to nothing.
            logger.info("Paste restore skipped: the clipboard was empty; dictation left on the clipboard.")
            return
        }
        let outcome = clipboard.restoreIfUnchanged(saved, dictation: text, revision: writtenRevision)
        guard isInsertionCurrent(generation) else { return }
        switch outcome {
        case .restored:
            break
        case .changed:
            logger.info("Clipboard changed during paste restore; leaving the new content alone.")
        case .unavailable:
            logger.notice("Paste restore skipped: clipboard access was unavailable.")
            notify(.restoreAccessUnavailable)
        case .failed(let preserved):
            if preserved {
                logger.error("Paste restore failed; dictation text was left on the clipboard.")
                notify(.restoreFailedDictationPreserved)
            } else {
                logger.error("Paste restore failed and the transcript could not be replaced on the clipboard.")
                notify(.restoreFailedDictationLost)
            }
        }
    }

}

extension AccessControlTextInserter {
    /// Clipboard fallback shared by the refused-insertion paths. The notice
    /// must match what actually happened: a failed copy says so instead of
    /// promising text that never landed.
    fileprivate func clipboardFallback(
        _ text: String, successNotice: InsertionNotice, concealed: Bool = false, generation: Int
    ) {
        guard isInsertionCurrent(generation) else { return }
        let written = copyToClipboard(text, concealed: concealed, generation: generation)
        guard isInsertionCurrent(generation) else { return }
        if written {
            notify(successNotice)
        } else {
            notify(.clipboardCopyFailed)
        }
    }

    @discardableResult
    fileprivate func copyToClipboard(_ text: String, concealed: Bool = false, generation: Int) -> Bool {
        // Concealed copies keep secrets out of clipboard history; every other
        // fallback copy is transient so managers do not archive dictation.
        let written = concealed ? clipboard.restore(.concealedText(text)) : clipboard.setTransientString(text)
        guard isInsertionCurrent(generation) else { return false }
        if !written {
            logger.error("Clipboard fallback failed: could not write text to the clipboard.")
            return false
        }
        return true
    }

    /// The not-yet-typed tail of a chunked insert, starting at the chunk
    /// that just failed (a failed post types nothing).
    static func untypedRemainder(_ chunks: [String], from index: Int) -> String {
        chunks.dropFirst(index).joined()
    }

    /// After writing dictation onto the pasteboard, restore the previous
    /// clipboard only when Cmd-V actually posted. A failed post must leave
    /// the dictation there — that is what the notice promised.
    static func pasteClipboardDisposition(didPost: Bool) -> PasteClipboardDisposition {
        didPost ? .restorePrevious : .keepDictation
    }
}
