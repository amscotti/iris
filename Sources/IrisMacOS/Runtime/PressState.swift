import Foundation
import IrisCore
import os

/// Lock-protected immutable configuration captured for each accepted press.
final class PressConfigurationBox: @unchecked Sendable {
    struct Snapshot: Sendable {
        var settings: AppSettings
        var config: ProviderConfiguration
    }
    private let lock = NSLock()
    private var snapshot: Snapshot

    init(settings: AppSettings, config: ProviderConfiguration) {
        snapshot = Snapshot(settings: settings, config: config)
    }
    func update(settings: AppSettings, config: ProviderConfiguration) {
        lock.withLock {
            snapshot.settings = settings
            snapshot.config = config
        }
    }
    func current() -> Snapshot { lock.withLock { snapshot } }
}

/// Sendable mirror of authorization state consulted by the press gate.
final class PermissionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    private var suspended = false
    private var staleImage = false
    private var cancelledBy: DictationNotice.CancellationReason?
    /// The first suspension owns this reason through its cleanup barrier.
    var cancellationReason: DictationNotice.CancellationReason? {
        get { lock.withLock { cancelledBy } }
        set { lock.withLock { cancelledBy = newValue } }
    }
    var microphoneGranted: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var captureSuspended: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }
    var requiresRelaunch: Bool {
        get { lock.withLock { staleImage } }
        set { lock.withLock { staleImage = newValue } }
    }
}

/// Authorization policy has no live defaults and no composition dependency.
enum RuntimeGate {
    static func make(permissions: PermissionSnapshot, authorization: CaptureAuthorization)
        -> DictationOrchestrator.BeginGate
    {
        let gateLog = Logger(subsystem: AppIdentity.identifier, category: "dictation")
        return {
            if permissions.requiresRelaunch {
                permissions.captureSuspended = true
                gateLog.notice("Press refused: the running app's code signature no longer matches.")
                return ApplicationImage.changedMessage
            }
            // A paused press is already refused; do not pay live
            // code-signature IPC until capture is otherwise eligible.
            guard !permissions.captureSuspended else {
                return "Dictation is paused while permissions or the login session change."
            }
            guard authorization.image() else {
                permissions.requiresRelaunch = true
                permissions.captureSuspended = true
                gateLog.notice("Press refused: the running app's code signature no longer matches.")
                return ApplicationImage.changedMessage
            }
            let microphone = authorization.microphone()
            permissions.microphoneGranted = microphone
            guard microphone else {
                gateLog.notice("Press refused: microphone access is off.")
                return "Microphone access is off. Enable it in Settings to dictate."
            }
            guard authorization.accessibility() else {
                gateLog.notice("Press refused: Accessibility trust is off.")
                return "Accessibility access is off. Enable it in Settings to dictate."
            }
            return nil
        }
    }
}
