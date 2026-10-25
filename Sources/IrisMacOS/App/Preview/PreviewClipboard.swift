#if DEBUG
    import Foundation

    /// Preview clipboard commands have no live fallback.
    struct PreviewClipboard: ClipboardPort {
        func string() -> String? { nil }
        func setString(_ text: String) -> Bool { false }
        func setTransientString(_ text: String) -> Bool { false }
        func clear() {}
        func snapshot() -> ClipboardSnapshot? { nil }
        func preparePaste(_ text: String, previous: ClipboardSnapshot?) -> ClipboardPasteOutcome { .unavailable }
        func restore(_ snapshot: ClipboardSnapshot) -> Bool { false }
        func restoreIfUnchanged(_ snapshot: ClipboardSnapshot, dictation: String, revision: Int)
            -> ClipboardRestoreOutcome
        { .unavailable }
        var changeCount: Int { -1 }
    }
#endif
