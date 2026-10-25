import Foundation

/// Exactly one configuration owner: standalone actor storage or a supplied
/// snapshot source. A live source has no unused mutable actor-side copy.
enum OrchestratorConfigurationOwner: Sendable {
    case stored(DictationOrchestrator.Configuration)
    case supplied(@Sendable () -> DictationOrchestrator.Configuration)

    var current: DictationOrchestrator.Configuration {
        switch self {
        case .stored(let value): return value
        case .supplied(let source): return source()
        }
    }
}

extension DictationOrchestrator {
    public struct Configuration: Sendable {
        public var settings: AppSettings
        public var config: ProviderConfiguration

        public init(settings: AppSettings, config: ProviderConfiguration) {
            self.settings = settings
            self.config = config
        }
    }

    /// Permission-style veto consulted before a press starts recording.
    /// A nil return proceeds; any message refuses the press and surfaces as
    /// an error state, so a blocked press never spins silently.
    public typealias BeginGate = @Sendable () async -> String?
    /// Platform capture lifecycle around a press. A starter message aborts
    /// the press before any provider session opens and surfaces as an error.
    public typealias PressStarter = @Sendable () async -> String?
    /// Take-aware capture startup, used to scope device failures to this press.
    public typealias PressStarterWithID = @Sendable (Int) async -> String?
    public typealias PressEnder = @Sendable () async -> Void
    /// Captures the insertion destination at press start. The orchestrator
    /// revalidates focus at insert time; a changed target is logged and still
    /// inserts into the focused app rather than silently following stale focus.
    public typealias InsertionTargetProvider = @Sendable () -> InsertionTargetSnapshot?

    /// Latched when an inserter misses its deadline (`insertionTimeout`
    /// plus this per-UTF-16-unit keystroke-pacing allowance).
    public static let insertionStalledMessage =
        "Text insertion stopped responding. Restart the app before dictating again."
    static let insertionSecondsPerUTF16Unit = 0.001
    /// Per-chunk allowance for the 5 ms pacing delay plus the trust and
    /// secure-field AX round trips. Character and chunk work are sequential,
    /// so both allowances contribute to the budget.
    static let insertionSecondsPerChunk = 0.05

    static func insertionBudgetSeconds(baseTimeout: Double, text: String) -> Double {
        let characterBudget = Double(text.utf16.count) * insertionSecondsPerUTF16Unit
        let chunkCount = max(1, DictationTextProcessor.chunk(text).count)
        let accessibilityBudget = Double(chunkCount) * insertionSecondsPerChunk
        return baseTimeout + characterBudget + accessibilityBudget
    }

    /// Extra grace when cleanup joins an in-flight insertion, covering the
    /// non-insertion teardown work that shares the same deadline.
    static let insertionJoinGraceSeconds = 0.5

    /// Cleanup normally waits the generic `shutdownTimeout`. An in-flight
    /// insertion instead gets its own remaining budget plus grace: a
    /// healthy but slow insert must not latch the restart meant for wedged
    /// inserters, and a wedged one still exhausts this bound and times out.
    static func cleanupJoinSeconds(for active: DictationTake, fallback shutdownTimeout: Double) -> Double {
        guard let started = active.insertionStartedUptime, let budget = active.insertionBudgetSeconds else {
            return shutdownTimeout
        }
        let remaining =
            started + budget + insertionJoinGraceSeconds - ProcessInfo.processInfo.systemUptime
        return max(shutdownTimeout, remaining)
    }
}
