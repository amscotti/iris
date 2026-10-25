import IrisCore

/// User-facing wording belongs to presentation and cannot change notice behavior.
enum NoticePresentation {
    /// Log only stable outcome metadata. Provider error details can contain
    /// request content and belong in the UI, never in diagnostics.
    static func logLabel(for notice: DictationNotice) -> String {
        switch notice {
        case .insertion(let reason): return "insertion/" + reason.rawValue
        case .cancelled: return "cancelled"
        case .restartRequired: return "restart-required"
        case .failure: return "failure"
        case .noSpeech: return "no-speech"
        }
    }

    static func message(for notice: DictationNotice) -> String {
        switch notice {
        case .insertion(let reason): return insertionMessages[reason] ?? "Dictation needs attention."
        case .cancelled(.settingsChange): return "A settings change cancelled the current dictation."
        case .cancelled(.systemEvent): return "The current dictation was cancelled."
        case .cancelled(.userRequested): return "The current dictation was cancelled at your request."
        case .cancelled(.microphoneDenied):
            return "Microphone access was lost. The current dictation was cancelled. Enable it in Settings to resume."
        case .cancelled(.accessibilityDenied):
            return
                "Accessibility access was lost. The current dictation was cancelled. Enable it in Settings to resume."
        case .restartRequired(let message), .failure(let message): return message
        case .noSpeech: return "No speech was recognized. Check your microphone input and try again."
        }
    }

    /// Presentation catalog; coverage requires an explicit message for every reason.
    static let insertionMessages: [InsertionNotice: String] = [
        .accessibilityOff: "Accessibility access is off. Text was copied to the clipboard instead.",
        .secureField: "The focused field is secure. Text was copied to the clipboard instead.",
        .keystrokesUnavailable: "Could not post keystrokes. Text was copied to the clipboard instead.",
        .partialClipboard:
            "Only the untyped part was copied to the clipboard. The already-typed prefix was not copied.",
        .clipboardCopyFailed: "Could not copy the transcript to the clipboard.",
        .clipboardWriteFailed: "Could not place text on the clipboard.",
        .clipboardChangedBeforePaste:
            "Paste was skipped because the clipboard changed. The transcript wasn’t inserted.",
        .clipboardRevisionUnavailable: "Couldn’t confirm the clipboard contents. Paste was skipped.",
        .pastePostFailed: "Couldn’t paste. The text is on the clipboard.",
        .previousClipboardUnavailable:
            "Your words were already pasted. The previous clipboard couldn’t be kept; "
            + "the transcript remains on the clipboard.",
        .concealedClipboardNotRestored:
            "Your words were already pasted. A copied password wasn’t restored for privacy; "
            + "the transcript remains on the clipboard.",
        .restoreAccessUnavailable:
            "Your words were already pasted. Clipboard access was unavailable, so the previous contents weren’t restored.",
        .restoreFailedDictationPreserved:
            "Your words were already pasted. The previous clipboard couldn’t be restored; "
            + "the transcript remains on the clipboard.",
        .restoreFailedDictationLost: "Your words were pasted; the previous clipboard couldn’t be restored or kept.",
    ]
}

/// How a retained dictation notice should rest in the menu bar. Outcomes
/// that are not failures (busy guidance, clipboard fallbacks, informational
/// cancellations) must not read as errors.
enum RetainedNoticeKind: Equatable {
    case busy
    case copied
    case informational
    case attention
    case failure
}

extension NoticePresentation {
    /// Mirrors `DictationOrchestrator.busyMessage` (internal to IrisCore);
    /// a unit test pins the two together so this match cannot drift.
    static let busyPressGuidance = "Finishing previous dictation — try again in a moment."

    static func noticeKind(for notice: DictationNotice) -> RetainedNoticeKind {
        if notice.severity == .information { return .informational }
        if notice.category == .copied { return .copied }
        return notice.severity == .warning ? .attention : .failure
    }

    static func noticeKind(forSnapshotErrorMessage message: String) -> RetainedNoticeKind {
        message == busyPressGuidance ? .busy : .failure
    }

    static func restingPresentation(
        for kind: RetainedNoticeKind
    ) -> (line: String, symbol: String) {
        switch kind {
        case .busy: return ("Finishing previous dictation…", "hourglass")
        case .copied: return ("Dictation copied to the clipboard", "doc.on.clipboard")
        case .informational: return ("Dictation cancelled", "mic.fill")
        case .attention: return ("Dictation needs attention", "exclamationmark.triangle")
        case .failure: return ("Dictation error", "exclamationmark.triangle")
        }
    }
}
