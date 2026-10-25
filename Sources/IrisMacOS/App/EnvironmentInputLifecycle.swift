import Foundation

/// UI actions acquire runtime suspension before invoking permission/credential
/// adapters. Hardware and task state remain private to DictationRuntime.
@MainActor
extension AppEnvironment {
    func beginPermissionChange() async {
        userPermissionOperationCount += 1
        await runtime.beginPermissionChange()
    }

    func endPermissionChange() {
        runtime.endPermissionChange()
        userPermissionOperationCount = max(0, userPermissionOperationCount - 1)
        // refreshPermissions schedules its own silent gate re-check when
        // the grants changed; only schedule one when it did not, so every
        // permission/credential action issues exactly one re-check.
        let gateScheduled = refreshPermissionDisplay()
        runtime.refreshAuthorization()
        if !gateScheduled {
            Task { await checkStartupGate(openSettingsWhenBlocked: false) }
        }
    }

    public func requestMicrophoneAccess() async {
        await beginPermissionChange()
        defer { endPermissionChange() }
        await permissions.requestMicrophone()
    }

    public func requestAccessibilityAccess() async {
        await beginPermissionChange()
        defer { endPermissionChange() }
        // The prompt may have granted trust already; only deep-link to
        // System Settings when still untrusted.
        if !permissions.requestAccessibility() {
            permissions.openAccessibilitySettings()
        }
    }

    public func resetPermissionAccess() async -> String? {
        await beginPermissionChange()
        defer { endPermissionChange() }
        return await permissions.resetPermissionState()
    }

    /// Settings reaches permission state and I/O through these commands without
    /// referencing the live adapter directly — including its types: the facade
    /// exposes only booleans and strings, never adapter-owned enums/structs.
    public var microphoneGranted: Bool { permissions.microphoneGranted }
    public var microphoneNeedsPrompt: Bool { permissions.microphoneStatus == .unknown }
    public var microphoneRestricted: Bool { permissions.microphoneStatus == .restricted }
    public var microphoneGuidance: String { permissions.microphoneGuidance }
    public var accessibilityGranted: Bool { permissions.accessibilityGranted }
    public var runsUnbundled: Bool { permissions.runsUnbundled }
    public func openMicrophoneSettings() { permissions.openMicrophoneSettings() }
    public func openAccessibilitySettings() { permissions.openAccessibilitySettings() }
    public func permissionDiagnosticLines() -> [String] { permissions.diagnostics().lines }
    public var permissionResetCommands: [String] { permissions.resetCommandsForThisApp }
    public var unbundledPermissionGuidance: String { PermissionsManager.unbundledGuidance }
    public var permissionResetExplanation: String { PermissionsManager.resetExplanation }

    /// Microphone heading text. A restricted microphone is policy, not a
    /// grant the user can still give: it must not read "Needs access".
    public var microphoneHeadingTitle: String {
        switch permissions.microphoneStatus {
        case .granted: "Allowed"
        case .restricted: "Restricted by policy"
        case .denied, .unknown: "Needs access"
        }
    }
}
