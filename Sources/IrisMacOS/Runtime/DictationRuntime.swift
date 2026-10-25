import Foundation
import IrisCore
import Observation

/// Sole owner of hardware, the hotkey generation, and asynchronous cleanup.
/// AppEnvironment is an observable UI model and never manipulates these tasks.
@MainActor
@Observable
public final class DictationRuntime {
    public private(set) var state: InputRuntimeState = .stopped
    public private(set) var isStarted = false
    public private(set) var permissionOperationCount = 0
    public private(set) var restartReason: String?
    public var onSnapshot: ((DictationSnapshot) -> Void)?
    public var onPermissionsChanged: (() -> Void)?
    public var onNotice: ((DictationNotice) -> Void)?
    let ports: DictationRuntimePorts
    let pressBox: PressConfigurationBox
    private let permissionBox: PermissionSnapshot
    let orchestrator: DictationOrchestrator
    private let timeline: PressTimelineLog
    private var runTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var cleanup: Task<SessionShutdown, Never>?
    private var systemAwake = true
    private var displayAwake = true
    private var sessionActive = true
    private var screenActive = true
    private var cancelledNoticeTakeID: Int?
    private var lifecycleGeneration = 0
    private var pendingPermissionReleases = 0

    public init(settings: AppSettings, registry: ProviderRegistry, ports: DictationRuntimePorts) {
        self.ports = ports
        let box = PressConfigurationBox(
            settings: settings, config: settings.providerConfiguration(using: registry))
        pressBox = box
        let permission = PermissionSnapshot()
        permissionBox = permission
        let timeline = PressTimelineLog()
        self.timeline = timeline
        let audio = ports.audio
        let authorization = ports.authorization
        let focus = ports.focus
        let cancellation = CancellationNoticeDelivery()
        orchestrator = DictationOrchestrator(
            audio: audio, inserter: ports.inserter, makeService: ports.makeService,
            settings: settings, config: settings.providerConfiguration(using: registry),
            gate: RuntimeGate.make(permissions: permission, authorization: authorization),
            pressStarterWithID: { id in
                await audio.setCaptureGeneration(id)
                do {
                    try await audio.start()
                    return nil
                } catch CaptureError.notAuthorized {
                    return "Microphone access is off. Enable it in Settings to dictate."
                } catch { return "Microphone unavailable. Check the input device and try again." }
            },
            pressEnder: {
                timeline.releaseBegan()
                await audio.stop()
                timeline.audioStopped()
            },
            configurationSource: {
                let value = box.current()
                return DictationOrchestrator.Configuration(settings: value.settings, config: value.config)
            }, rewriteFactory: ports.rewriteFactory,
            insertionTargetProvider: { focus.currentTargetSnapshot() }, shutdownTimeout: ports.shutdownTimeout,
            onCancelledTake: { [permission, cancellation] id, requestedReason in
                guard let reason = requestedReason ?? permission.cancellationReason else { return }
                await cancellation.send(id: id, reason: reason)
            })
        observeCaptureFailures(audio, orchestrator: orchestrator)
        cancellation.handler = { [weak self] id, reason in
            guard let self, self.isStarted, !self.requiresRestart, id != self.cancelledNoticeTakeID else { return }
            self.cancelledNoticeTakeID = id
            self.onNotice?(.cancelled(reason))
        }
        ports.inserter.onNotice { [weak self] notice in
            Task { @MainActor in self?.onNotice?(.insertion(notice)) }
        }
        update(settings: settings, config: settings.providerConfiguration(using: registry))
    }

    /// Device loss is reported off the audio task. The handler must not await
    /// shutdown: the forwarder is the task that shutdown joins. The weak
    /// capture keeps the orchestrator↔capturer graph from retaining each
    /// other; if the orchestrator is gone, the failure has no take to end.
    private func observeCaptureFailures(
        _ audio: any AudioCaptureLifecycle, orchestrator: DictationOrchestrator
    ) {
        let permission = permissionBox
        audio.setCaptureFailureHandler { [weak orchestrator] takeID, message in
            guard !permission.captureSuspended, let orchestrator else { return }
            Task {
                guard !permission.captureSuspended else { return }
                await orchestrator.failCapture(message, expectedTakeID: takeID)
            }
        }
    }

    public var isMonitoring: Bool { ports.hotkey.isMonitoring }
    public var captureSuspended: Bool { permissionBox.captureSuspended }
    public var requiresRestart: Bool { restartReason != nil }
    public func start() async {
        guard !isStarted else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isStarted = true
        let snapshots = await orchestrator.snapshots()
        guard isStarted, lifecycleGeneration == generation else { return }
        observation = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self, self.lifecycleGeneration == generation else { return }
                self.timeline.note(snapshot.state)
                if snapshot.requiresRestart {
                    self.requireRestart(snapshot.lastError ?? TranscriptionService.restartMessage)
                }
                if snapshot.lastError != nil {
                    switch snapshot.state {
                    case .recording, .partial, .enhancing: break
                    default: self.refreshAuthorization()
                    }
                }
                self.onSnapshot?(snapshot)
            }
        }
        ports.systemEvents.start { [weak self] event in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.handle(event)
        }
        refreshAuthorization()
    }

    public func stop() async {
        isStarted = false
        systemAwake = true
        displayAwake = true
        sessionActive = true
        screenActive = true
        lifecycleGeneration += 1
        let retiringObservation = observation
        observation = nil
        ports.systemEvents.stop()
        reconcile()
        _ = await waitForCleanup()
        // A concurrent start owns a different observation. Never cancel it
        // when this retiring generation finally completes its cleanup.
        retiringObservation?.cancel()
    }

    public func refreshAuthorization() {
        if permissionBox.requiresRelaunch { requireRestart(ApplicationImage.changedMessage) }
        permissionBox.microphoneGranted = ports.authorization.microphone()
        reconcile()
        // Refresh ticks and wake/activation paths also close a hold whose
        // key-up disappeared. A stopped monitor performs no physical probe.
        if isStarted, ports.hotkey.isMonitoring { ports.hotkey.reconcile() }
    }

    func handle(_ event: RuntimeSystemEvent) {
        switch event {
        case .sleep: systemAwake = false
        case .wake: systemAwake = true
        case .displaySleep: displayAwake = false
        case .displayWake: displayAwake = true
        case .sessionInactive: sessionActive = false
        case .sessionActive: sessionActive = true
        case .screenLocked: screenActive = false
        case .screenUnlocked: screenActive = true
        case .refresh: break
        }
        if systemAwake && displayAwake && sessionActive && screenActive {
            refreshAuthorization()
            onPermissionsChanged?()
        } else {
            reconcile()
        }
    }

    public func beginPermissionChange() async {
        beginPermissionHold()
        _ = await waitForCleanup()
    }

    func beginPermissionHold() {
        // A release can win the same-actor scheduling gap and land before
        // this begin's prologue: consume the queued release instead of
        // incrementing, so the pair stays balanced rather than leaving an
        // unbalanced count suspended forever.
        if pendingPermissionReleases > 0 {
            pendingPermissionReleases -= 1
        } else {
            permissionOperationCount += 1
        }
        // The actual stop publishes the take ID once within bounded cleanup.
        reconcile()
    }

    public func endPermissionChange() {
        if permissionOperationCount == 0 {
            // No begin has landed yet; the paired begin will consume this
            // instead of incrementing. Dropping it here would strand that
            // begin's increment with no future release.
            pendingPermissionReleases += 1
        } else {
            permissionOperationCount -= 1
        }
        refreshAuthorization()
    }

    @discardableResult
    public func waitForCleanup() async -> SessionShutdown {
        await cleanup?.value ?? (requiresRestart ? .timedOut : .clean)
    }

    private func reconcile() {
        let lifecycleAwake = systemAwake && displayAwake
        let lifecycleSessionActive = sessionActive && screenActive
        let needsAccessibility =
            restartReason == nil && isStarted && lifecycleAwake && lifecycleSessionActive
            && permissionOperationCount == 0 && permissionBox.microphoneGranted
        state =
            InputReadiness(
                started: isStarted, systemAwake: lifecycleAwake, sessionActive: lifecycleSessionActive,
                permissionOperations: permissionOperationCount, microphoneGranted: permissionBox.microphoneGranted,
                accessibilityGranted: needsAccessibility ? ports.authorization.accessibility() : false,
                cleaningUp: cleanup != nil, restartReason: restartReason
            ).state
        permissionBox.captureSuspended = !state.isReady
        guard state.isReady else {
            suspend()
            return
        }
        guard runTask == nil else { return }
        guard ports.hotkey.start() else {
            state = .suspended(.accessibilityDenied)
            permissionBox.captureSuspended = true
            return
        }
        let input = RuntimeHotkeyFeed(stream: ports.hotkey.events())
        runTask = Task.detached { [orchestrator] in await orchestrator.run(hotkey: input) }
    }

    /// Headroom over `shutdownTimeout` before a cleanup join that still has
    /// not settled is declared wedged. The orchestrator's own join budget
    /// already covers an in-flight insertion (insertion timeout plus
    /// per-character pacing plus grace), which the runtime does not own; a
    /// healthy but slow insert must not latch the restart meant for wedged
    /// resources.
    static let suspendJoinHeadroomSeconds: Double = 45

    private func suspend() {
        guard cleanup == nil else { return }
        permissionBox.cancellationReason = isStarted ? state.cancellationReason : nil
        let previous = runTask
        runTask = nil
        previous?.cancel()
        ports.hotkey.stop()
        guard previous != nil else {
            permissionBox.cancellationReason = nil
            return
        }
        cleanup = Task { [weak self, orchestrator, timeout = ports.shutdownTimeout] in
            // Read the take's own remaining insertion budget before asking
            // the orchestrator to stop. A fixed outer ceiling must not
            // contradict a healthy, longer insertion budget.
            let insertionJoinBudget = await orchestrator.currentCleanupJoinSeconds
            let result: SessionShutdown
            do {
                result = try await AsyncDeadline.run(seconds: timeout, ignoringCancellation: true) {
                    async let closed = orchestrator.stop()
                    await previous?.value
                    return await closed
                }
            } catch {
                // The generic deadline expired while cleanup was still
                // joining under the orchestrator's own, insertion-aware
                // budget. Keep waiting for that verdict — re-calling stop()
                // rejoins the same pending shutdown — and latch a restart
                // only if the join itself times out or never settles within
                // a generous hard ceiling.
                result = await AsyncDeadline.shutdown(
                    seconds: max(Self.suspendJoinHeadroomSeconds, insertionJoinBudget + 2)
                ) {
                    _ = await previous?.value
                    await orchestrator.stop()
                }
            }
            guard let self else { return result }
            if result == .timedOut { self.requireRestart(TranscriptionService.restartMessage) }
            self.cleanup = nil
            self.permissionBox.cancellationReason = nil
            self.reconcile()
            return result
        }
    }

    private func requireRestart(_ message: String) {
        guard restartReason == nil else { return }
        restartReason = message
        onNotice?(.restartRequired(message))
        // The orchestrator can latch quarantine independently of the runtime
        // cleanup path. Converge readiness and observer ownership immediately
        // instead of leaving a Ready menu and a live but refused hotkey.
        reconcile()
    }
}

private struct RuntimeHotkeyFeed: HotkeyMonitoring {
    let stream: AsyncStream<HotkeyEvent>
    func events() -> AsyncStream<HotkeyEvent> { stream }
}

/// A main-actor delivery target can be injected before runtime initialization
/// finishes; its handler is installed afterward and retains the runtime weakly.
@MainActor
private final class CancellationNoticeDelivery {
    var handler: ((Int, DictationNotice.CancellationReason) -> Void)?
    func send(id: Int, reason: DictationNotice.CancellationReason) { handler?(id, reason) }
}
