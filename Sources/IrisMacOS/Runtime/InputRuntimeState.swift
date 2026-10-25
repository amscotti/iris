import Foundation
import IrisCore

/// Explicit input-runtime state. The individual readiness flags remain as
/// inputs, but lifecycle decisions switch on this single value instead of
/// coordinating independent booleans at each call site.
public enum InputRuntimeState: Sendable, Equatable {
    case stopped
    case suspended(InputSuspensionReason)
    case cleaningUp(InputSuspensionReason)
    case ready
    case restartRequired(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var suspensionReason: InputSuspensionReason? {
        switch self {
        case .suspended(let reason), .cleaningUp(let reason):
            return reason
        case .stopped, .ready:
            return nil
        case .restartRequired: return .requiresRelaunch
        }
    }

    /// Capture the cause that actually suspended input, including externally
    /// revoked grants, rather than reconstructing it from partial flags.
    var cancellationReason: DictationNotice.CancellationReason? {
        switch suspensionReason {
        case .systemAsleep, .sessionInactive: return .systemEvent
        case .permissionOperation: return .settingsChange
        case .microphoneDenied: return .microphoneDenied
        case .accessibilityDenied: return .accessibilityDenied
        default: return nil
        }
    }
}

public enum InputSuspensionReason: Sendable, Equatable {
    case systemAsleep
    case sessionInactive
    case permissionOperation
    case requiresRelaunch
    case microphoneDenied
    case accessibilityDenied
    case cleaningUpPreviousGeneration
}
