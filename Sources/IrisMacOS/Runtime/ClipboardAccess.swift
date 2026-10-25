import Foundation
import os

/// AppKit access stays serialized, but waiting for another operation is bounded.
/// A promised-data read can remain stuck after its caller abandons it; subsequent
/// insertion and Settings operations must fail promptly without touching AppKit
/// concurrently or claiming a clipboard write succeeded. A lease still gone
/// `leaseStuckSeconds` after the first timeout cannot belong to a bounded
/// operation and is replaced so clipboard functions recover — the abandoned
/// holder's late signal lands on the retired semaphore, and the rare overlap
/// is both accepted and logged.
final class ClipboardAccess: @unchecked Sendable {
    /// Every bounded operation finishes far sooner than this; only an
    /// abandoned read can hold the lease longer.
    static let defaultLeaseStuckSeconds: TimeInterval = 5

    private let lock = NSLock()
    private let waitSeconds: TimeInterval
    private let leaseStuckSeconds: TimeInterval
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "clipboard")
    private var gate = DispatchSemaphore(value: 1)
    private var stuckSince: DispatchTime?

    init(
        waitSeconds: TimeInterval = 0.2,
        leaseStuckSeconds: TimeInterval = ClipboardAccess.defaultLeaseStuckSeconds
    ) {
        self.waitSeconds = waitSeconds
        self.leaseStuckSeconds = leaseStuckSeconds
    }

    func withAccess<Value>(or fallback: Value, _ operation: () -> Value) -> Value {
        guard let gate = acquireGate() else { return fallback }
        defer { gate.signal() }
        return operation()
    }

    /// Main-thread callers (Settings copy/read) fail fast instead of
    /// parking the UI for the full wait budget under a held lease.
    private var waitBudget: TimeInterval { Thread.isMainThread ? 0 : waitSeconds }

    private enum AcquireOutcome {
        case acquired(DispatchSemaphore)
        case timedOut
        /// Another thread already replaced the gate; retry on the live one
        /// rather than reporting unavailable.
        case gateRotated
    }

    private func acquireGate() -> DispatchSemaphore? {
        for _ in 0..<3 {
            switch acquireGateOnce() {
            case .acquired(let gate): return gate
            case .timedOut: return nil
            case .gateRotated: continue
            }
        }
        return nil
    }

    private enum EnterResult {
        case entered
        case timedOut
        /// Entered on a gate another thread already retired; signal handed back.
        case retired
    }

    private func tryEnter(_ gate: DispatchSemaphore) -> EnterResult {
        guard gate.wait(timeout: .now() + waitBudget) == .success else { return .timedOut }
        let stillCurrent = lock.withLock { () -> Bool in
            guard self.gate === gate else { return false }
            stuckSince = nil
            return true
        }
        if stillCurrent { return .entered }
        gate.signal()
        return .retired
    }

    private enum Recovery {
        case rotated
        case notStuck
        case replaced(DispatchSemaphore)
    }

    private func recoveryDecision(for gate: DispatchSemaphore) -> Recovery {
        lock.withLock {
            guard self.gate === gate else { return .rotated }
            let now = DispatchTime.now()
            guard let since = stuckSince else {
                stuckSince = now
                return .notStuck
            }
            let elapsed = Double(now.uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000_000
            guard elapsed >= leaseStuckSeconds else { return .notStuck }
            stuckSince = nil
            let replacement = DispatchSemaphore(value: 1)
            self.gate = replacement
            return .replaced(replacement)
        }
    }

    /// Waits for the lease, replacing it once it is provably stuck. A late
    /// signal from an abandoned holder can satisfy the wait on a gate the
    /// access already retired; that entry is discarded and retried on the
    /// live gate so a replacement holder and a stale waiter never overlap.
    private func acquireGateOnce() -> AcquireOutcome {
        let gate = lock.withLock { self.gate }
        switch tryEnter(gate) {
        case .entered: return .acquired(gate)
        case .retired:
            let replacement = lock.withLock { self.gate }
            switch tryEnter(replacement) {
            case .entered: return .acquired(replacement)
            case .timedOut: return .timedOut
            case .retired: return .gateRotated
            }
        case .timedOut: break
        }
        switch recoveryDecision(for: gate) {
        case .rotated: return .gateRotated
        case .notStuck: return .timedOut
        case .replaced(let recovered):
            guard recovered.wait(timeout: .now() + waitBudget) == .success else { return .timedOut }
            logger.notice("Replaced a clipboard lease stuck since an abandoned read.")
            return .acquired(recovered)
        }
    }
}
