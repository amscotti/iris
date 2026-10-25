import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import IrisCore

/// Explicit insertion destination captured at press start and revalidated
/// at insert time. The policy is deliberate: the recorded target marks the
/// press-start session boundary and is diagnostic (a pid change is logged),
/// but insertion always follows the currently focused app at insert time —
/// matching `TextInserting`'s "focused app at insert time" contract. The
/// inserter never retargets a stale app on its own.
public struct InsertionTarget: Sendable, Equatable {
    public var pid: Int32?
    public var bundleID: String?

    public init(pid: Int32? = nil, bundleID: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Every item on the pasteboard with all of its typed representations, in
/// order. Paste-mode insertion restores this exactly, so images, files, rich
/// text, and marker types such as `org.nspasteboard.ConcealedType` (which
/// password managers use to keep secrets out of clipboard history) survive.
public struct ClipboardSnapshot: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    /// nspasteboard.org convention password managers use to mark secrets.
    public static let concealedType = "org.nspasteboard.ConcealedType"

    public var items: [[Representation]]
    /// Ownership metadata, not part of content equality or restoration bytes.
    public var revision: Int?

    public init(items: [[Representation]] = [], revision: Int? = nil) {
        self.items = items
        self.revision = revision
    }

    public static func == (lhs: ClipboardSnapshot, rhs: ClipboardSnapshot) -> Bool { lhs.items == rhs.items }

    public var isEmpty: Bool { items.isEmpty }

    /// One plain-text item marked concealed, so clipboard history skips it.
    public static func concealedText(_ text: String) -> ClipboardSnapshot {
        ClipboardSnapshot(items: [
            [
                Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)),
                Representation(type: concealedType, data: Data()),
            ]
        ])
    }
    /// True when any item is a password manager's concealed secret.
    public var isConcealed: Bool { items.contains { $0.contains { $0.type == Self.concealedType } } }
}

/// Outcome of an attempted conditional clipboard restore.
/// `changed` means someone else wrote first: leave their content alone.
/// `unavailable` never authorizes mutation. Recovery from an owned write failure
/// happens inside the same access lease and reports whether dictation survived.
public enum ClipboardRestoreOutcome: Sendable, Equatable {
    case restored, changed, unavailable
    case failed(dictationPreserved: Bool)
}

public enum ClipboardPasteOutcome: Sendable, Equatable {
    /// The previous snapshot is returned only if its revision was still current.
    case written(revision: Int, previous: ClipboardSnapshot?)
    case unavailable, changed, failed
}

/// Result of reading clipboard text without conflating an unavailable
/// bounded lease with a clipboard that simply has no text.
public enum ClipboardTextRead: Sendable, Equatable {
    case text(String)
    case empty
    case unavailable
    /// A password manager marked the item concealed; it is not a key draft.
    case concealed
}

public protocol ClipboardPort: Sendable {
    func string() -> String?
    func readString() -> ClipboardTextRead
    /// Replaces the clipboard with one plain-text item, removing stale formats.
    @discardableResult func setString(_ text: String) -> Bool
    /// Writes `text` marked `org.nspasteboard.TransientType` so clipboard
    /// history managers skip the temporary paste-mode copy.
    @discardableResult func setTransientString(_ text: String) -> Bool
    func clear()
    /// Captures every item and type currently on the pasteboard, or nil when
    /// the content is too large, or reading it has already been too slow.
    /// The time budget is checked between reads: one slow promised type can
    /// still take longer than the budget to render.
    func snapshot() -> ClipboardSnapshot?
    /// Writes transient dictation and captures its revision under one lease.
    /// An unavailable lease never mutates. Any owned-write rollback is completed
    /// before returning, using only a previous snapshot whose revision matched.
    func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome
    /// Replaces the pasteboard contents with `snapshot`.
    @discardableResult func restore(_ snapshot: ClipboardSnapshot) -> Bool
    /// Replaces the pasteboard with `snapshot` only if it still holds
    /// `dictation` at `revision`. The re-check runs inside this call,
    /// immediately before clearing, so no app code runs between the check
    /// and the write. (No OS-level transaction exists; a writer landing in
    /// that instant can still be clobbered.)
    func restoreIfUnchanged(_ snapshot: ClipboardSnapshot, dictation: String, revision: Int)
        -> ClipboardRestoreOutcome
    /// Monotonic pasteboard revision, bumped by every write — ours included.
    /// A negative value means access was unavailable and must not authorize paste.
    /// Restore decisions compare against the revision captured right after
    /// writing, so a user copy that landed in between is never clobbered.
    var changeCount: Int { get }
}

extension ClipboardPort {
    public func readString() -> ClipboardTextRead {
        string().map(ClipboardTextRead.text) ?? .empty
    }
}

public protocol FocusPort: Sendable {
    func isProcessTrusted() -> Bool
    func focusedIsSecure() -> Bool
    func currentTarget() -> InsertionTarget?
    func currentTargetSnapshot() -> InsertionTargetSnapshot?
}

extension FocusPort {
    public func currentTargetSnapshot() -> InsertionTargetSnapshot? {
        guard let target = currentTarget() else { return nil }
        return InsertionTargetSnapshot(pid: target.pid, bundleID: target.bundleID)
    }
}

public protocol KeyPostingPort: Sendable {
    func postUnicodeString(_ chunk: String) -> Bool
    func postPasteCommand() -> Bool
    func canPost() -> Bool
}

public struct LiveFocus: FocusPort {
    public init() {}
    public func isProcessTrusted() -> Bool { AXIsProcessTrusted() }
    public func focusedIsSecure() -> Bool { AccessControlTextInserter.focusedFieldIsSecure() }
    public func currentTarget() -> InsertionTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 1.0)
        var focusedApp: AnyObject?
        guard
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
                == .success,
            let rawApp = focusedApp, CFGetTypeID(rawApp) == AXUIElementGetTypeID()
        else { return nil }
        let app = unsafeDowncast(rawApp, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return nil }
        var bundleID: String?
        if let running = NSRunningApplication(processIdentifier: pid) {
            bundleID = running.bundleIdentifier
        }
        return InsertionTarget(
            pid: pid, bundleID: bundleID)
    }
}

public struct LiveKeyPosting: KeyPostingPort {
    public init() {}
    public func canPost() -> Bool { CGEventSource(stateID: .combinedSessionState) != nil }
    public func postUnicodeString(_ chunk: String) -> Bool {
        guard !chunk.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .combinedSessionState),
            let (down, keyUp) = Self.unicodeKeyEvents(chunk, source: source)
        else { return false }
        down.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Key-down carrying `chunk` plus a bare key-up. Both clear modifier
    /// flags: events from the combined session source otherwise inherit keys
    /// the person is holding, so a held ⌘ would turn the chunk (virtual key
    /// 0, "A") into Select All. The key-up deliberately has no payload; a
    /// second payload would risk a duplicated string from the HID tap.
    static func unicodeKeyEvents(_ chunk: String, source: CGEventSource?) -> (CGEvent, CGEvent)? {
        let units = Array(chunk.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return nil }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.flags = []
        keyUp.flags = []
        return (down, keyUp)
    }
    public func postPasteCommand() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let keyCode = Self.pasteKeyCode(source: source)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        keyUp.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static let ansiVKeyCode: CGKeyCode = 9

    /// Resolves the virtual key code that produces `"v"` under the active
    /// keyboard layout (fast-pathing ANSI `v` = 9, scanning when remapped
    /// e.g. Dvorak = 47, and falling back to 9 on non-Latin layouts).
    private static func pasteKeyCode(source: CGEventSource) -> CGKeyCode {
        if keyProducesV(ansiVKeyCode, source: source) { return ansiVKeyCode }
        for candidate in CGKeyCode(0)..<128 where candidate != ansiVKeyCode {
            if keyProducesV(candidate, source: source) { return candidate }
        }
        return ansiVKeyCode
    }

    private static func keyProducesV(_ keyCode: CGKeyCode, source: CGEventSource) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return false
        }
        event.flags = []
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length == 1 else { return false }
        return chars[0] == 0x76 || chars[0] == 0x56
    }
}
