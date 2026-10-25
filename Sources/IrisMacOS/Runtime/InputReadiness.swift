import Foundation

/// Pure readiness evaluation; live authorization queries happen at the caller.
struct InputReadiness: Sendable {
    var started: Bool
    var systemAwake: Bool
    var sessionActive: Bool
    var permissionOperations: Int
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var cleaningUp: Bool
    var restartReason: String?

    var state: InputRuntimeState {
        if let restartReason { return .restartRequired(restartReason) }
        if !started { return .stopped }
        let reason: InputSuspensionReason?
        if !systemAwake {
            reason = .systemAsleep
        } else if !sessionActive {
            reason = .sessionInactive
        } else if permissionOperations > 0 {
            reason = .permissionOperation
        } else if !microphoneGranted {
            reason = .microphoneDenied
        } else if !accessibilityGranted {
            reason = .accessibilityDenied
        } else {
            reason = nil
        }
        if let reason { return cleaningUp ? .cleaningUp(reason) : .suspended(reason) }
        return cleaningUp ? .cleaningUp(.cleaningUpPreviousGeneration) : .ready
    }
}
