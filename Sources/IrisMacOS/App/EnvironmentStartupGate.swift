import Foundation
import IrisCore
import os

/// Whether the active provider's required secrets can be used.
enum SecretReadiness: Equatable {
    case present
    case missing
    case unavailable
}

/// Launch readiness gate: computes whether dictation can run and, when
/// blocked at launch, marks the menu-bar state and opens Settings on the
/// Permissions tab. Later re-checks clear silently instead of nagging.
@MainActor
extension AppEnvironment {
    /// Readiness snapshot from live permission state plus key presence.
    /// Keychain read failures are a separate blocker from a missing key.
    public func readiness(
        apiKeyPresent: Bool, keyAccessUnavailable: Bool = false, providerAvailable: Bool = true
    ) -> StartupReadiness {
        StartupReadiness.evaluate(
            microphoneGranted: permissions.microphoneGranted,
            accessibilityGranted: permissions.accessibilityGranted,
            apiKeyPresent: apiKeyPresent, keyAccessUnavailable: keyAccessUnavailable,
            microphoneRestricted: permissions.microphoneStatus == .restricted,
            providerAvailable: providerAvailable)
    }

    /// Recomputes launch readiness from permissions, secrets, and whether
    /// settings could be read. While blocked, a runtime suspension hold keeps
    /// the hotkey loop from running on defaults; the hold releases when the
    /// gate passes. Overlapping checks keep only the latest result: readiness
    /// is read again after every await, and a stale check neither opens
    /// Settings nor releases a hold `stop()` already dropped.
    public func checkStartupGate(openSettingsWhenBlocked: Bool) async {
        guard !stopping else { return }
        startupGateGeneration += 1
        let token = startupGateGeneration
        if openSettingsWhenBlocked { openSettingsPending = true }
        guard let snapshot = await startupGateSnapshot() else {
            // The provider switched mid-check, so this check's target no
            // longer exists. Drop any launch-open intent it latched: the
            // switch's own re-check decides afresh, and a stale latch would
            // otherwise pop Settings open from an unrelated later check.
            openSettingsPending = false
            return
        }
        guard token == startupGateGeneration else { return }
        applyStartupGate(snapshot)
        guard snapshot.blocked else {
            openSettingsPending = false
            releaseStartupGateHold()
            return
        }
        await acquireStartupGateHold()
        guard token == startupGateGeneration else { return }
        guard let current = await startupGateSnapshot() else {
            if token == startupGateGeneration { openSettingsPending = false }
            return
        }
        guard token == startupGateGeneration else { return }
        applyStartupGate(current)
        guard current.blocked else {
            openSettingsPending = false
            releaseStartupGateHold()
            return
        }
        surfaceBlockedGate(current, requestedOpen: openSettingsWhenBlocked)
    }

    /// The blocked tail of a gate check: log why, then open Settings when
    /// this check asked for it or a superseded launch check latched that
    /// intent. No awaits run between the caller's generation check and the
    /// window decision.
    private func surfaceBlockedGate(_ current: StartupGateSnapshot, requestedOpen: Bool) {
        if current.loadIssue != nil {
            logger.notice("Launch blocked: settings could not be read.")
        }
        if !current.readiness.missingItems.isEmpty {
            let names = current.readiness.missingItems.map(\.label).joined(separator: ", ")
            logger.notice("Launch requirements missing: \(names, privacy: .public).")
        }
        let shouldOpenSettings = requestedOpen || openSettingsPending
        openSettingsPending = false
        guard shouldOpenSettings else { return }
        openSettingsBlocked(missing: current.readiness.missingItems)
    }

    /// Presents Settings on the pane that names the first blocking item.
    private func openSettingsBlocked(missing: [StartupReadiness.MissingItem]) {
        if missing.isEmpty {
            openSettingsWindow()
        } else if missing.allSatisfy({ $0 == .apiKey || $0 == .keyAccess || $0 == .providerUnavailable }) {
            selectedSettingsTab = .providers
            openSettingsWindow()
        } else {
            selectedSettingsTab = .permissions
            openSettingsWindow()
        }
    }

    private struct StartupGateSnapshot {
        var readiness: StartupReadiness
        var loadIssue: String?
        var blocked: Bool { !readiness.isReady || loadIssue != nil }
    }

    private func startupGateSnapshot() async -> StartupGateSnapshot? {
        let provider = settings.providerName
        let secret = await secretReadiness(provider: provider)
        guard settings.providerName == provider else { return nil }
        return StartupGateSnapshot(
            readiness: readiness(
                apiKeyPresent: secret == .present, keyAccessUnavailable: secret == .unavailable,
                providerAvailable: registry.descriptor(forName: provider) != nil),
            loadIssue: settingsLoadIssue)
    }

    private func applyStartupGate(_ snapshot: StartupGateSnapshot) {
        startupBlockers = snapshot.readiness.missingItems
        startupLimited = snapshot.blocked
        applyRestingStatus()
    }

    /// Key presence for the startup gate: every secret the provider's
    /// descriptor requires. An empty secret list is present (Mock). A
    /// Keychain failure stays `.unavailable` so the menu can offer
    /// unlock instead of "add a key".
    func secretReadiness(provider: String) async -> SecretReadiness {
        let required: Set<String>
        if let descriptor = registry.descriptor(forName: provider) {
            required = descriptor.secretKeys
        } else {
            required = [ProviderConfiguration.Key.apiKey]
        }
        guard !required.isEmpty else { return .present }
        await loadProviderCredentials(provider)
        guard settings.providerName == provider else { return .missing }
        if case .unavailable = credentials.state(for: provider) { return .unavailable }
        return providerAccess.hasRequiredSecrets(provider) ? .present : .missing
    }

    func beginStartupGateHold() {
        guard !startupGateHold else { return }
        startupGateHold = true
        runtime.beginPermissionHold()
    }

    /// Holds a runtime suspension while the gate is blocked. The flag is set
    /// before awaiting so concurrent re-checks cannot double-acquire.
    func acquireStartupGateHold() async {
        beginStartupGateHold()
        _ = await runtime.waitForCleanup()
    }

    func releaseStartupGateHold() {
        guard startupGateHold else { return }
        startupGateHold = false
        runtime.endPermissionChange()
    }

    /// Opens the Settings scene without leaving accessory policy, so Iris
    /// stays out of the Dock.
    public func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(environment: self)
        }
        settingsWindowController?.present()
    }
}
