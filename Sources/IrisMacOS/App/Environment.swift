import Foundation
import IrisCore
import Observation
import os

/// Observable application UI model. Persistence, credentials, and the input
/// runtime have independent owners; live adapters are supplied by composition.
@MainActor
@Observable
public final class AppEnvironment {
    let permissions: PermissionsManager
    public let pill = PillController()
    public let registry: ProviderRegistry
    let runtime: DictationRuntime
    public let settingsController: SettingsController
    public let providerAccess: ProviderAccessController
    public var credentials: ProviderCredentials { providerAccess.credentials }
    public var connections: ProviderConnections { providerAccess.connections }
    public let isSettingsPreview: Bool

    public var settings: AppSettings { settingsController.settings }
    public var statusLine = "Iris"
    public var menuSymbol = "mic.fill"
    public var selectedSettingsTab: SettingsTab = .providers {
        didSet {
            settingsWindowController?.select(selectedSettingsTab)
            // Pane chrome uses raw persistence, not the settings lock.
            do {
                try persistence.save(selectedSettingsTab.rawValue, forKey: SettingsTab.storageKey)
            } catch {
                logger.error(
                    "Could not save the selected settings pane: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    @ObservationIgnored var settingsWindowController: SettingsWindowController?
    /// True only after the initial runtime start has completed; prevents the
    /// menu from advertising a hotkey before its monitor exists.
    public private(set) var hasFinishedInitialStartup = false
    /// True while a launch blocker is outstanding; drives the menu-bar state.
    public var startupLimited = false
    public var startupBlockers: [StartupReadiness.MissingItem] = []
    /// Menu-facing blockers: a restricted microphone is blocked by system
    /// policy, which an "Allow…" remedy cannot fix.
    public var menuStartupBlockers: [StartupReadiness.MissingItem] {
        guard permissions.microphoneStatus == .restricted else { return startupBlockers }
        return startupBlockers.map { $0 == .microphone ? .microphoneBlockedByPolicy : $0 }
    }
    public var credentialErrors: [String: String] { providerAccess.errors }
    public internal(set) var lastDictationError: String?
    /// Latest non-empty final, retained in memory for explicit recovery copies.
    public private(set) var lastDictationText: String?
    public private(set) var isTakeActive = false
    public private(set) var activeTakeID: Int?
    public private(set) var isInsertionActive = false
    public var canCancelDictation: Bool {
        isTakeActive && !isInsertionActive && activeTakeID != nil
    }
    /// Presentation class of `lastDictationError` while that message is set.
    var retainedNoticeKind: RetainedNoticeKind = .failure
    public var settingsLoadIssue: String? { settingsController.loadIssue }
    public var settingsSaveError: String? { settingsController.saveError }
    /// True while an interactive permission/credential action is running.
    /// The startup gate's suspension hold and launch-time checks use the
    /// runtime counter directly, so a blocked gate never disables the very
    /// permission controls that clear it.
    public var permissionOperationInProgress: Bool { userPermissionOperationCount > 0 }
    private let persistence: any PersistenceProviding
    let clipboard: any ClipboardPort
    /// Test seam for the async runtime request; production always uses the runtime.
    @ObservationIgnored var cancelDictationForTesting: (@MainActor (Int) async -> Bool)?
    let logger = Logger(subsystem: AppIdentity.identifier, category: "dictation")
    private var started = false
    var stopping = false
    private var lastTerminalRevision = 0
    private var lastBusyPressRevision = 0
    /// Interactive permission/credential operations currently running;
    /// drives `permissionOperationInProgress` for the Settings UI. The
    /// startup gate hold is deliberately excluded (see
    /// `EnvironmentInputLifecycle.swift`).
    var userPermissionOperationCount = 0
    /// Counts a runtime suspension held while the startup gate is blocked
    /// (missing key), so dictation stays suspended — not just menu-flagged —
    /// until the gate passes. Managed by `EnvironmentStartupGate.swift`.
    var startupGateHold = false
    /// Bumped by every gate check and by `stop()`. A check that resumes
    /// after a newer check, or after stop, leaves the hold and the window alone.
    var startupGateGeneration = 0
    /// Latch set by a superseded launch check that intended to open
    /// Settings. The newest check consumes it on its blocked path, so a
    /// silent re-check that supersedes the launch check still surfaces
    /// Settings exactly once; an unblocked check clears it.
    var openSettingsPending = false
    /// Set around the legacy-secret scrub save. That save publishes a settings
    /// change, and the change must not schedule a second gate check that
    /// would invalidate the launch check responsible for opening Settings.
    var suppressStartupGateRecheck = false

    public init(
        persistence: any PersistenceProviding,
        secrets: any SecretStoring,
        registry: ProviderRegistry,
        permissions: PermissionsManager,
        runtimePorts: DictationRuntimePorts,
        connections: ProviderConnections,
        clipboard: any ClipboardPort,
        defaults: AppSettings,
        isSettingsPreview: Bool = false
    ) {
        self.persistence = persistence
        self.clipboard = clipboard
        self.registry = registry
        self.providerAccess = ProviderAccessController(secrets: secrets, registry: registry, connections: connections)
        self.permissions = permissions
        self.isSettingsPreview = isSettingsPreview
        settingsController = SettingsController(persistence: persistence, registry: registry, defaults: defaults)
        if settingsController.loadIssue != nil {
            Logger(subsystem: AppIdentity.identifier, category: "dictation").error(
                "Stored settings need recovery; persistence is blocked.")
        }
        if let raw = try? persistence.load(key: SettingsTab.storageKey, as: String.self),
            let pane = SettingsTab(rawValue: raw)
        {
            selectedSettingsTab = pane
        }
        runtime = DictationRuntime(settings: settingsController.settings, registry: registry, ports: runtimePorts)
        settingsController.onChange = { [weak self] change in self?.settingsChanged(change) }
        applyLocalSettings()
        publishConfiguration()
    }

    /// Starts the hotkey loop and the pill/status observation. Idempotent.
    /// Input stays suspended across credential resolution and the first
    /// gate check, so the hotkey can never run half-initialized; observers
    /// are attached before any authorization I/O so early restart notices
    /// are never dropped.
    public func start() async {
        guard !started else { return }
        stopping = false
        started = true
        runtime.onNotice = { [weak self] notice in
            guard let self else { return }
            self.retainNotice(NoticePresentation.message(for: notice), kind: NoticePresentation.noticeKind(for: notice))
            self.pill.handle(notice)
            self.applyRestingStatus()
        }
        runtime.onSnapshot = { [weak self] snapshot in self?.handleSnapshot(snapshot) }
        runtime.onPermissionsChanged = { [weak self] in
            self?.refreshPermissionDisplay()
        }
        await runtime.beginPermissionChange()
        await resolveConfiguration()
        guard started else {
            runtime.endPermissionChange()
            return
        }
        applyLocalSettings()
        refreshPermissions()
        await importPlaintextSecrets()
        guard started else {
            runtime.endPermissionChange()
            return
        }
        await checkStartupGate(openSettingsWhenBlocked: true)
        guard started else {
            runtime.endPermissionChange()
            return
        }
        await runtime.start()
        runtime.endPermissionChange()
        if started, !stopping, runtime.isStarted {
            hasFinishedInitialStartup = true
        }
    }

    public func stop() async {
        started = false
        hasFinishedInitialStartup = false
        stopping = true
        startupGateGeneration += 1
        openSettingsPending = false
        // Stop observers before releasing the gate hold: releasing it while
        // the runtime is still started could briefly reinstall the hotkey.
        await runtime.stop()
        if startupGateHold {
            startupGateHold = false
            runtime.endPermissionChange()
        }
        teardownSettingsWindow()
    }

    /// Releases the Settings window. Its hosted SwiftUI tree retains this
    /// environment strongly, so without explicit teardown the
    /// environment → controller → window → content view cycle keeps both
    /// alive forever. Reopening builds a fresh window from the saved frame.
    func teardownSettingsWindow() {
        settingsWindowController?.teardown()
        settingsWindowController = nil
    }

    /// Re-reads mic and Accessibility state. Call on activation and when
    /// settings open; recording never starts while access is ungranted.
    public func refreshPermissions() {
        refreshPermissionDisplay()
        runtime.refreshAuthorization()
    }

    /// Refreshes the permission display, scheduling a silent gate re-check
    /// when the grants changed while started. Returns whether that check
    /// was scheduled, so `endPermissionChange` can avoid scheduling a
    /// second concurrent one.
    @discardableResult
    func refreshPermissionDisplay() -> Bool {
        let previous = (permissions.microphoneGranted, permissions.accessibilityGranted)
        let previousMicrophoneStatus = permissions.microphoneStatus
        permissions.refreshMicrophoneStatus()
        permissions.refreshAccessibilityStatus()
        if previous.0 != permissions.microphoneGranted, !permissions.microphoneGranted {
            logger.info("Microphone access is not granted; dictation stays disabled.")
        }
        if previous.1 != permissions.accessibilityGranted, !permissions.accessibilityGranted {
            logger.info("Accessibility trust is not granted; hotkey and insertion stay disabled.")
        }
        let grantsChanged =
            previous != (permissions.microphoneGranted, permissions.accessibilityGranted)
            || previousMicrophoneStatus != permissions.microphoneStatus
        if grantsChanged, started {
            Task { await checkStartupGate(openSettingsWhenBlocked: false) }
            return true
        }
        return false
    }

    /// Persists new settings and applies them to the live graph.
    /// Save failures are surfaced instead of silently keeping memory-only state.
    public func saveSettings(_ updated: AppSettings) {
        settingsController.save(updated)
    }

    private func settingsChanged(_ change: SettingsController.Change) {
        providerAccess.settingsChanged(change.invalidatedProviders)
        applyLocalSettings()
        // Hold input BEFORE publishing: the press path reads the published
        // configuration through a lock-free box, so publishing first would
        // open a window where a press starts with the new provider's
        // not-yet-loaded (nil) key.
        if change.refreshCredentials, !suppressStartupGateRecheck,
            runtime.isStarted || started,
            !providerAccess.hasRequiredSecrets(settings.providerName)
                || registry.descriptor(forName: settings.providerName) == nil
        {
            beginStartupGateHold()
        }
        publishConfiguration()
        if change.refreshCredentials, !suppressStartupGateRecheck {
            Task {
                await importPlaintextSecrets()
                await resolveConfiguration()
                await checkStartupGate(openSettingsWhenBlocked: false)
            }
        }
    }

}

@MainActor
extension AppEnvironment {
    // MARK: - Rewrite prompts (see EnvironmentPrompts.swift)

    private func applyLocalSettings() {
        pill.applyAppearance(
            reduceMotionOverride: settings.reduceMotion,
            waveformColorHex: settings.waveformColorHex,
            pillTranslucent: settings.pillTranslucent)
    }

    func retainNotice(_ message: String, kind: RetainedNoticeKind) {
        lastDictationError = message
        retainedNoticeKind = kind
    }

    func clearRetainedNotice() {
        lastDictationError = nil
    }

    func handleStatus(_ state: PushToTalkState) {
        switch state {
        case .idle:
            applyRestingStatus()
        case .final(let text):
            let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isEmpty { lastDictationText = text }
            if isEmpty {
                retainNotice(
                    NoticePresentation.message(for: .noSpeech), kind: NoticePresentation.noticeKind(for: .noSpeech))
            } else if lastDictationError == NoticePresentation.busyPressGuidance {
                // The take's final supersedes busy guidance adopted while it
                // was still finishing. Real errors name their own failure and
                // survive; they clear when the next take starts recording.
                clearRetainedNotice()
            }
            applyRestingStatus()
        case .recording, .partial:
            clearRetainedNotice()
            statusLine = "Listening…"
            menuSymbol = "waveform"
        case .enhancing:
            if lastDictationError == NoticePresentation.busyPressGuidance {
                clearRetainedNotice()
            }
            statusLine = "Rewriting…"
            menuSymbol = "sparkles"
        case .error(let message):
            // The message is user-facing guidance, never transcript text.
            // The pill stays clear of errors; the menu bar carries them.
            // Server-supplied details can echo request content. Keep them in
            // the UI and log only the event, even in private log mode.
            logger.error("Dictation error surfaced; details are available in the menu.")
            retainNotice(message, kind: NoticePresentation.noticeKind(forSnapshotErrorMessage: message))
            applyRestingStatus()
        }
    }

    func handleSnapshot(_ snapshot: DictationSnapshot) {
        isTakeActive = snapshot.isTakeActive
        activeTakeID = snapshot.activeTakeID
        isInsertionActive = snapshot.isInsertionActive
        // Only adopt errors from the snapshot; never clear here. A notice
        // set by a terminal state (e.g. "No speech was recognized" from an
        // empty final) must survive the trailing idle snapshot that follows
        // it. It clears when the next take reaches `.recording`.
        if runtime.requiresRestart {
            if let message = runtime.restartReason ?? snapshot.lastError {
                retainNotice(message, kind: .failure)
            } else {
                clearRetainedNotice()
            }
        } else if let lastError = snapshot.lastError {
            switch snapshot.state {
            case .recording, .partial, .enhancing: break
            default:
                retainNotice(lastError, kind: NoticePresentation.noticeKind(forSnapshotErrorMessage: lastError))
            }
        }
        if snapshot.busyPressRevision != lastBusyPressRevision {
            lastBusyPressRevision = snapshot.busyPressRevision
            // Busy guidance arrives here without replacing a retained final.
            if snapshot.state == .idle, !runtime.requiresRestart {
                retainNotice(NoticePresentation.busyPressGuidance, kind: .busy)
            }
        }
        if runtime.requiresRestart {
            pill.handle(.idle)
            applyRestingStatus()
            return
        }
        if snapshot.state == .idle, snapshot.terminalRevision != lastTerminalRevision,
            let terminal = snapshot.lastTerminal
        {
            pill.handle(terminal)
            handleStatus(terminal)
        } else {
            pill.handle(snapshot.state)
        }
        lastTerminalRevision = snapshot.terminalRevision
        handleStatus(snapshot.state)
        if snapshot.isInsertionActive {
            statusLine = "Inserting…"
            menuSymbol = "text.cursor"
        }
    }

    func applyRestingStatus() {
        if requiresRelaunch {
            statusLine = "Restart Iris to resume dictation"
            menuSymbol = "exclamationmark.triangle"
        } else if settingsLoadIssue != nil {
            statusLine = "Settings could not be read"
            menuSymbol = "exclamationmark.triangle"
        } else if startupLimited {
            statusLine = "Iris setup needed"
            menuSymbol = "exclamationmark.triangle"
        } else if lastDictationError != nil {
            let presentation = NoticePresentation.restingPresentation(for: retainedNoticeKind)
            statusLine = presentation.line
            menuSymbol = presentation.symbol
        } else {
            statusLine = "Ready"
            menuSymbol = "mic.fill"
        }
    }

}
