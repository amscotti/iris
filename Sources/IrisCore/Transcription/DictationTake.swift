import Foundation

/// Resources belong to a take, not to reusable flags on the orchestrator.
/// Late callbacks carry the id and cannot mutate a later take's resources.
struct DictationTake {
    typealias Phase = TakeLifecycle.Phase
    let id: Int
    let settings: AppSettings
    let rewrite: PromptRewrite?
    /// Resolved off-actor during startup (the live provider runs AX
    /// queries); nil until `targetResolution` lands.
    var target: InsertionTargetSnapshot?
    var targetResolution: Task<InsertionTargetSnapshot?, Never>?
    var lifecycle = TakeLifecycle()
    var phase: Phase { lifecycle.phase }
    var service: TranscriptionService?
    var startup: Task<Bool, Never>?
    var finalization: Task<Void, Never>?
    /// Soft session-limit timer. It only requests normal finalization and is
    /// cancelled with the rest of this take's owned work.
    var softDeadline: Task<Void, Never>?
    var gate: Task<String?, Never>?
    var captureStart: Task<String?, Never>?
    var captureStop: Task<Void, Never>?
    var audio: Task<Void, Never>?
    var forward: Task<Void, Never>?
    var processing: Task<RewritePrompt.Outcome, Never>?
    var insertion: Task<Void, Never>?
    var errorReported = false
    /// Budget and start (monotonic uptime) of the insertion tail, so
    /// cleanup can join it under the insertion's own remaining deadline
    /// instead of the generic shutdown timeout.
    var insertionBudgetSeconds: Double?
    var insertionStartedUptime: Double?
    /// The busy notice uses its own latch so it cannot consume the take's
    /// one real error report.
    var busyNoticeReported = false
    /// When the take entered `.recording`, on the monotonic uptime clock so
    /// a wall-clock adjustment cannot change the accidental-tap verdict.
    /// Takes that end almost immediately with no transcript are discarded
    /// silently (see `DictationOrchestrator.isSilentQuickTake`).
    var recordingBeganUptime: Double?
    /// Whether any non-blank transcript text arrived. A take that produced
    /// text is never silent, however quickly it ended.
    var hadTranscript = false
    /// `DictationOrchestrator.terminalRevision` when the press was reserved.
    /// A busy press may replace a terminal only when this take has not
    /// already published one. A previous take's final must not swallow the
    /// notice for a press that arrives while this take is still recording.
    let terminalRevisionAtStart: Int

    func cancelOwnedTasks(includingCaptureStop: Bool = false) {
        targetResolution?.cancel()
        startup?.cancel()
        finalization?.cancel()
        softDeadline?.cancel()
        gate?.cancel()
        captureStart?.cancel()
        if includingCaptureStop { captureStop?.cancel() }
        audio?.cancel()
        forward?.cancel()
        processing?.cancel()
    }
}

public struct DictationSnapshot: Sendable, Equatable {
    public let state: PushToTalkState
    public let lastError: String?
    public let requiresRestart: Bool
    public let terminalRevision: Int
    public let lastTerminal: PushToTalkState?
    /// Monotonic count of refused presses whose busy guidance could not be
    /// represented as a terminal without replacing the retained take result.
    /// UI observers use changes to surface that guidance on a separate channel.
    public let busyPressRevision: Int
    /// Whether a take currently owns capture, finalization, or insertion work.
    public let isTakeActive: Bool
    /// Identity used to scope a delayed cancellation request to one take.
    public let activeTakeID: Int?
    /// Insertion is joined, not cancelled by ordinary take cancellation.
    public let isInsertionActive: Bool

    public init(
        state: PushToTalkState, lastError: String?, requiresRestart: Bool, terminalRevision: Int,
        lastTerminal: PushToTalkState?, busyPressRevision: Int = 0, isTakeActive: Bool = false,
        activeTakeID: Int? = nil, isInsertionActive: Bool = false
    ) {
        self.state = state
        self.lastError = lastError
        self.requiresRestart = requiresRestart
        self.terminalRevision = terminalRevision
        self.lastTerminal = lastTerminal
        self.busyPressRevision = busyPressRevision
        self.isTakeActive = isTakeActive
        self.activeTakeID = activeTakeID
        self.isInsertionActive = isInsertionActive
    }
}
