import Foundation

/// Stable presentation semantics travel independently of localized/user-facing text.
public enum DictationNotice: Sendable, Equatable {
    public enum Category: Sendable, Equatable { case problem, copied }
    public enum Severity: Sendable, Equatable { case information, warning, error }
    public enum CancellationReason: Sendable, Equatable {
        case settingsChange, systemEvent, microphoneDenied, accessibilityDenied, userRequested
    }

    case insertion(InsertionNotice)
    case cancelled(CancellationReason)
    case restartRequired(String)
    case failure(String)
    case noSpeech

    public var category: Category {
        if case .insertion(let reason) = self { return reason.category }
        return .problem
    }
    public var severity: Severity {
        switch self {
        case .cancelled(.microphoneDenied), .cancelled(.accessibilityDenied): return .warning
        case .cancelled: return .information
        case .insertion(let reason): return reason.severity
        case .noSpeech: return .warning
        case .restartRequired, .failure: return .error
        }
    }
}

public enum InsertionNotice: String, Sendable, Equatable, CaseIterable {
    case accessibilityOff, secureField, keystrokesUnavailable, partialClipboard
    case clipboardCopyFailed, clipboardWriteFailed, clipboardChangedBeforePaste, clipboardRevisionUnavailable
    case pastePostFailed, previousClipboardUnavailable, concealedClipboardNotRestored
    case restoreAccessUnavailable, restoreFailedDictationPreserved, restoreFailedDictationLost

    public var category: DictationNotice.Category {
        switch self {
        case .accessibilityOff, .secureField, .keystrokesUnavailable, .partialClipboard, .pastePostFailed,
            .previousClipboardUnavailable, .concealedClipboardNotRestored, .restoreFailedDictationPreserved:
            return .copied
        case .clipboardCopyFailed, .clipboardWriteFailed, .clipboardChangedBeforePaste,
            .clipboardRevisionUnavailable, .restoreAccessUnavailable, .restoreFailedDictationLost:
            return .problem
        }
    }
    public var severity: DictationNotice.Severity {
        // The dictation itself was pasted; only the previous clipboard was
        // lost. That needs attention, not a dictation-error presentation.
        if self == .restoreFailedDictationLost { return .warning }
        return category == .copied ? .warning : .error
    }
}
