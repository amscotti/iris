import Foundation

/// Owns per-take resources and insertion; missed cleanup deadlines require restart.
public actor DictationOrchestrator {
    public typealias ServiceFactory = @Sendable (ProviderConfiguration) -> TranscriptionService
    private let audio: any AudioCapturing
    private let inserter: (any TextInserting)?
    private let makeService: ServiceFactory
    let gate: BeginGate?
    let pressStarter: PressStarter?
    let pressStarterWithID: PressStarterWithID?
    private let pressEnder: PressEnder?
    private let rewriteRunner: PromptRewrite?
    private let rewriteFactory: (@Sendable (ProviderConfiguration) -> PromptRewrite?)?
    let insertionTargetProvider: InsertionTargetProvider?
    let onCancelledTake: (@Sendable (Int, DictationNotice.CancellationReason?) async -> Void)?
    let shutdownTimeout: Double
    private let insertionTimeout: Double
    private let pumpTimeout: Double
    /// Ends the take through normal finalization before the provider's hard
    /// streaming cap can reject the audio and discard recognized speech.
    let softTakeTimeout: Double
    let silentTakeSeconds: Double
    private var configuration: OrchestratorConfigurationOwner
    var take: DictationTake?
    var generation = 0
    var shutdownTask: Task<SessionShutdown, Never>?
    /// Bumped per shutdown assignment; a close clears only its own slot.
    var shutdownGeneration = 0
    var shutdownBusyNoticeReported = false
    private var current: PushToTalkState = .idle
    var lastError: String?
    private var terminalRevision = 0
    var busyPressRevision = 0
    var lastTerminal: PushToTalkState?
    private let observations = StateBroadcast<PushToTalkState>()
    let snapshotObservers = StateBroadcast<DictationSnapshot>()
    private let terminalObservers = StateBroadcast<PushToTalkState>()
    public private(set) var requiresRestart = false

    public init(
        audio: any AudioCapturing, inserter: (any TextInserting)? = nil,
        makeService: @escaping ServiceFactory, settings: AppSettings = .defaults,
        config: ProviderConfiguration, gate: BeginGate? = nil, pressStarter: PressStarter? = nil,
        pressStarterWithID: PressStarterWithID? = nil, pressEnder: PressEnder? = nil,
        rewriteRunner: PromptRewrite? = nil,
        configurationSource: (@Sendable () -> Configuration)? = nil,
        rewriteFactory: (@Sendable (ProviderConfiguration) -> PromptRewrite?)? = nil,
        insertionTargetProvider: InsertionTargetProvider? = nil, shutdownTimeout: Double = 2,
        insertionTimeout: Double = 10, pumpTimeout: Double = 20,
        softTakeTimeout: Double = SessionDriver.maxSessionSeconds - 30, silentTakeSeconds: Double = 2,
        onCancelledTake: (@Sendable (Int, DictationNotice.CancellationReason?) async -> Void)? = nil
    ) {
        self.audio = audio
        self.inserter = inserter
        self.makeService = makeService
        configuration =
            configurationSource.map(OrchestratorConfigurationOwner.supplied)
            ?? .stored(Configuration(settings: settings, config: config))
        self.gate = gate
        self.pressStarter = pressStarter
        self.pressStarterWithID = pressStarterWithID
        self.pressEnder = pressEnder
        self.rewriteRunner = rewriteRunner
        self.rewriteFactory = rewriteFactory
        self.insertionTargetProvider = insertionTargetProvider
        self.onCancelledTake = onCancelledTake
        self.shutdownTimeout = shutdownTimeout
        self.insertionTimeout = insertionTimeout
        self.pumpTimeout = pumpTimeout
        self.softTakeTimeout = softTakeTimeout
        self.silentTakeSeconds = silentTakeSeconds
    }

    public var currentState: PushToTalkState { current }
    public var isPressActive: Bool { take != nil }
    /// The press mode that governs the next hotkey edge.
    var activeHotkeyMode: HotkeyConfiguration.Mode {
        take?.settings.hotkey.mode ?? configuration.current.settings.hotkey.mode
    }
    var isRecording: Bool { take?.phase == .recording }
    var currentTake: DictationTake? { take }
    var subscriberCount: Int { observations.count }

    /// Updates locally owned configuration. A supplied source owns its updates;
    /// return false instead of silently changing an unused shadow snapshot.
    @discardableResult
    public func update(settings: AppSettings, config: ProviderConfiguration) -> Bool {
        guard case .stored = configuration else { return false }
        configuration = .stored(Configuration(settings: settings, config: config))
        return true
    }

    /// Lossless diagnostic events. UI uses snapshots() (one-element buffer).
    public func states() -> AsyncStream<PushToTalkState> { observations.stream(initial: current) }
    public func snapshots() -> AsyncStream<DictationSnapshot> {
        snapshotObservers.stream(initial: snapshot, buffering: .bufferingNewest(1))
    }
    public func terminalEvents() -> AsyncStream<PushToTalkState> { terminalObservers.stream() }
    public var snapshot: DictationSnapshot {
        DictationSnapshot(
            state: current, lastError: lastError, requiresRestart: requiresRestart,
            terminalRevision: terminalRevision, lastTerminal: lastTerminal,
            busyPressRevision: busyPressRevision, isTakeActive: take != nil,
            activeTakeID: take?.id, isInsertionActive: take?.insertion != nil)
    }

    /// Starts a take. Returns false when the press is refused (a take is
    /// already active, a shutdown is running, a restart is required, or the
    /// task was cancelled); callers that need user feedback for the busy
    /// case should use `reportBusyPress()`.
    @discardableResult
    public func pressBegan() async -> Bool {
        guard let startup = beginPress(), let id = take?.id else { return false }
        let started = await joinOwnedTask(startup, id: id)
        if Task.isCancelled {
            cancelTake(id: id)
            _ = await waitForCleanup()
            return false
        }
        if !started { _ = await waitForCleanup() }
        return started
    }

    /// Reserve ownership before scheduling startup, so an immediately queued
    /// release can cancel it even before its task has started running.
    func beginPress() -> Task<Bool, Never>? {
        guard take == nil, shutdownTask == nil, !requiresRestart, !Task.isCancelled else { return nil }
        generation += 1
        let id = generation
        let configuration = self.configuration.current
        let rewrite = rewriteFactory.map { $0(configuration.config) } ?? rewriteRunner
        take = DictationTake(
            id: id, settings: configuration.settings,
            rewrite: rewrite, target: nil,
            terminalRevisionAtStart: terminalRevision)
        lastError = nil
        snapshotObservers.send(snapshot)
        let startup = Task { await self.startTake(id: id, configuration: configuration) }
        take?.startup = startup
        return startup
    }

    private func startTake(id: Int, configuration: Configuration) async -> Bool {
        guard stillStarting(id: id) else { return false }
        guard await resolveTarget(id: id) else { return false }
        guard await runStartupGates(id: id) else { return false }
        let service = makeService(configuration.config)
        take?.service = service
        let pending = await service.states()
        guard stillStarting(id: id) else {
            await service.cancel()
            return false
        }
        take?.forward = Task { await self.forward(pending, id: id) }
        do { try await service.start(config: configuration.config) } catch {
            guard stillStarting(id: id) else { return false }
            reportFailure((error as? TranscriptionError)?.message ?? error.localizedDescription, id: id)
            _ = requestStop(preservingError: true)
            return false
        }
        guard isCurrent(id), take?.lifecycle.captureReady() == true else {
            await service.cancel()
            return false
        }
        take?.recordingBeganUptime = ProcessInfo.processInfo.systemUptime
        scheduleSoftTakeDeadline(id: id)
        if take?.captureStop == nil { take?.audio = Task { await self.pumpAudio(into: service, id: id) } }
        return true
    }

    public func pressEnded() async {
        let id = take?.id
        if let finalization = beginFinalization(), let id { await joinOwnedTask(finalization, id: id) }
        if Task.isCancelled, let id { cancelTake(id: id) }
        _ = await waitForCleanup()
    }

    func finalizeTake(_ active: DictationTake) async {
        let id = active.id
        guard await stopCapture(id: id) == .clean, isCurrent(id) else { return }
        let pump = take?.audio
        do { try await AsyncDeadline.run(seconds: pumpTimeout) { await pump?.value } } catch {
            await pumpDeadlineExceeded(error, active: active, id: id)
            return
        }
        guard isCurrent(id), let service = active.service else { return }
        let result = await service.finish()
        guard isCurrent(id) else { return }
        await take?.forward?.value
        guard isCurrent(id) else { return }
        let serviceRequiresRestart = await service.requiresRestart
        guard isCurrent(id) else { return }
        if serviceRequiresRestart {
            // A final retained before a hung cleanup is still dictation. Insert
            // it before quarantining the orchestrator; genuine failures skip
            // this path and retain the restart error.
            if case .completed = result { await completeTake(result, active: active, id: id) }
            requireRestart()
            return
        }
        await completeTake(result, active: active, id: id)
    }

    /// Insertion tail of a finished take: optional rewrite, one insertion,
    /// then release. `take` is cleared here (not after the call) so the
    /// insertion stays tracked on the take until it completes.
    func completeTake(_ result: TranscriptionOutcome, active: DictationTake, id: Int) async {
        guard isCurrent(id) else { return }
        if case .completed(let text) = result {
            let enhanced = await enhance(text, take: active)
            guard isCurrent(id) else { return }
            await insertPrepared(enhanced, for: active)
            guard isCurrent(id) else { return }
        }
        take = nil
        snapshotObservers.send(snapshot)
    }

    /// Bounded across capture startup, provider shutdown, audio delivery, and
    /// forwarding. Timing out quarantines this orchestrator until app restart.
    @discardableResult
    public func stop() async -> SessionShutdown {
        await requestStop(notifyingCancellation: true)?.value ?? (requiresRestart ? .timedOut : .clean)
    }

    func waitForCleanup() async -> SessionShutdown {
        await shutdownTask?.value ?? (requiresRestart ? .timedOut : .clean)
    }
}

extension DictationOrchestrator {
    /// Insertion pacing (`Thread.sleep` between keystroke chunks, the paste
    /// restore window) is blocking work. It runs on a blocking GCD worker so
    /// the orchestrator actor suspends instead of holding its executor —
    /// `stop()` and cleanup deadlines stay responsive during long/paste
    /// inserts. The task is registered on the take so `stop()` joins it
    /// within its shutdown deadline: a cancelled generation cannot overlap
    /// the next take's insertion, and posted events that already landed are
    /// the only part that cannot be recalled. Callers re-check `isCurrent`
    /// after resuming. A wedged inserter (stalled AX/pasteboard call) misses
    /// the bounded wait and latches a visible restart instead of a silent hang.
    private func insertPrepared(_ text: String, for active: DictationTake) async {
        guard
            let prepared = DictationTextProcessor.prepare(
                text, trailingSpace: active.settings.trailingSpace, trailingNewline: active.settings.trailingNewline)
        else { return }
        guard let inserter else { return }
        let target = active.target
        let insertion = Task { [inserter] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    inserter.insert(prepared, target: target)
                    continuation.resume()
                }
            }
        }
        take?.insertion = insertion
        snapshotObservers.send(snapshot)
        let budget = Self.insertionBudgetSeconds(baseTimeout: insertionTimeout, text: prepared)
        take?.insertionBudgetSeconds = budget
        take?.insertionStartedUptime = ProcessInfo.processInfo.systemUptime
        let outcome = await AsyncDeadline.shutdown(seconds: budget) { await insertion.value }
        // The latch also applies when a concurrent stop already cleared the
        // take: the stop's own join is still waiting on this insertion, and
        // the specific diagnosis must win over the generic shutdown one.
        if outcome == .timedOut, take == nil || take?.id == active.id {
            // AsyncDeadline abandons the await, not the blocking worker. Give
            // the inserter a generation invalidation seam before quarantining
            // so a late AX/pasteboard return cannot post into a new focus.
            inserter.cancelInsertion()
            requireRestart(message: Self.insertionStalledMessage)
        }
    }

    func captureStopTask(for active: DictationTake) -> Task<Void, Never> {
        if let existing = active.captureStop { return existing }
        return Task { [pressEnder] in
            _ = await active.captureStart?.value
            if let pressEnder { await pressEnder() } else { active.audio?.cancel() }
        }
    }

    func stopCapture(id: Int) async -> SessionShutdown {
        guard let active = take, active.id == id else { return .clean }
        let task = captureStopTask(for: active)
        take?.captureStop = task
        let result = await AsyncDeadline.shutdown(seconds: shutdownTimeout) { await task.value }
        if result == .timedOut, isCurrent(id) { requireRestart() }
        return result
    }

    private func pumpAudio(into service: TranscriptionService, id: Int) async {
        for await frame in audio.frames() {
            guard isCurrent(id) else { return }
            do { try await service.appendAudio(frame) } catch {
                guard isCurrent(id), !(error is CancellationError) else { return }
                await service.failAudioDelivery(error)
                _ = await stopCapture(id: id)
                return
            }
        }
    }

    func requireRestart(message: String = TranscriptionService.restartMessage) {
        let active = take
        generation += 1
        take = nil
        active?.cancelOwnedTasks(includingCaptureStop: true)
        // First latch wins on the message: a caller that already latched a
        // specific diagnosis (e.g. the insertion-stall sentence) keeps it.
        let resolved = requiresRestart ? (lastError ?? message) : message
        requiresRestart = true
        lastError = resolved
        note(.idle)
    }

    func note(_ state: PushToTalkState) {
        current = state
        switch state {
        case .error(let message):
            lastError = message
            recordTerminal(state)
        case .final:
            // The take's own final supersedes a busy notice retained from a
            // press that landed before the final was published.
            if lastError == Self.busyMessage { lastError = nil }
            recordTerminal(state)
        default: break
        }
        observations.send(state)
        snapshotObservers.send(snapshot)
    }

    private func recordTerminal(_ state: PushToTalkState) {
        terminalRevision += 1
        lastTerminal = state
        terminalObservers.send(state)
    }
}
