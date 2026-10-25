import AppKit
import CoreGraphics
import Foundation

/// Owns native notification tokens and permission refresh cadence. Runtime
/// tests replace this adapter, including its clock, with an explicit event feed.
///
/// The readiness poll is a 30-second MainActor-isolated tick so `stop()`
/// reliably suppresses the trailing tick; notification observers remain the
/// primary wake path.
///
/// Lifetime: `stop()` is the prompt teardown path. Block-based observers are
/// retained by their notification centers until `removeObserver` runs, so the
/// nonisolated `ObserverTokens` holder below repeats that teardown in its
/// `deinit` when the adapter deallocates without `stop()` (the poll task
/// holds only a weak reference and ends on its next tick either way).
@MainActor
final class SystemEvents: SystemEventObserving {
    /// Low-frequency readiness re-check cadence.
    static let pollInterval: Duration = .seconds(30)
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private static let workspaceEvents: [(Notification.Name, RuntimeSystemEvent)] = [
        (NSWorkspace.willSleepNotification, .sleep),
        (NSWorkspace.screensDidSleepNotification, .displaySleep),
        (NSWorkspace.didWakeNotification, .wake),
        (NSWorkspace.screensDidWakeNotification, .displayWake),
        (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
        (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
    ]
    private static let distributedEvents: [(Notification.Name, RuntimeSystemEvent)] = [
        (screenLockedNotification, .screenLocked),
        (screenUnlockedNotification, .screenUnlocked),
    ]

    static func workspaceEvent(for name: Notification.Name) -> RuntimeSystemEvent? {
        workspaceEvents.first(where: { $0.0 == name })?.1
    }

    static func distributedEvent(for name: Notification.Name) -> RuntimeSystemEvent? {
        distributedEvents.first(where: { $0.0 == name })?.1
    }

    static func screenLockEvent(isLocked: Bool) -> RuntimeSystemEvent {
        isLocked ? .screenLocked : .screenUnlocked
    }

    static func isScreenLocked(_ session: [String: Any]?) -> Bool {
        session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func currentScreenLockEvent() -> RuntimeSystemEvent {
        screenLockEvent(isLocked: isScreenLocked(CGSessionCopyCurrentDictionary() as? [String: Any]))
    }

    private struct ObserverRegistration {
        let activation: NSObjectProtocol
        let workspaceCenter: NotificationCenter
        let workspace: [NSObjectProtocol]
        let distributedCenter: DistributedNotificationCenter
        let distributed: [NSObjectProtocol]
        let poll: Task<Void, Never>
    }

    /// Nonisolated teardown holder. `SystemEvents` is `@MainActor`, so its
    /// nonisolated `deinit` cannot touch isolated state; keeping the tokens,
    /// captured centers, and poll task here lets cleanup run on deallocation
    /// from any thread without re-entering the main actor. Both notification
    /// centers are captured on `start()` so `deinit` never resolves shared
    /// workspace or distributed centers.
    private final class ObserverTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var activation: NSObjectProtocol?
        private var workspaceCenter: NotificationCenter?
        private var workspace: [NSObjectProtocol] = []
        private var distributedCenter: DistributedNotificationCenter?
        private var distributed: [NSObjectProtocol] = []
        private var poll: Task<Void, Never>?

        func install(_ registration: ObserverRegistration) {
            lock.withLock {
                activation = registration.activation
                workspaceCenter = registration.workspaceCenter
                workspace = registration.workspace
                distributedCenter = registration.distributedCenter
                distributed = registration.distributed
                poll = registration.poll
            }
        }

        func removeAll() {
            let (poll, activation, workspaceCenter, workspace, distributedCenter, distributed) = lock.withLock {
                let current = (
                    self.poll, self.activation, self.workspaceCenter, self.workspace,
                    self.distributedCenter, self.distributed
                )
                self.poll = nil
                self.activation = nil
                self.workspaceCenter = nil
                self.workspace.removeAll()
                self.distributedCenter = nil
                self.distributed.removeAll()
                return current
            }
            poll?.cancel()
            if let activation { NotificationCenter.default.removeObserver(activation) }
            if let workspaceCenter {
                for observer in workspace { workspaceCenter.removeObserver(observer) }
            }
            if let distributedCenter {
                for observer in distributed { distributedCenter.removeObserver(observer) }
            }
        }

        deinit {
            removeAll()
        }
    }

    private let tokens = ObserverTokens()

    func start(_ handler: @escaping @MainActor (RuntimeSystemEvent) -> Void) {
        stop()
        let activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler(Self.currentScreenLockEvent())
                handler(.refresh)
            }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        var workspace: [NSObjectProtocol] = []
        for (name, event) in Self.workspaceEvents {
            workspace.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    _ in MainActor.assumeIsolated { handler(event) }
                })
        }
        let distributedCenter = DistributedNotificationCenter.default()
        var distributed: [NSObjectProtocol] = []
        for (name, event) in Self.distributedEvents {
            distributed.append(
                distributedCenter.addObserver(forName: name, object: nil, queue: .main) {
                    _ in MainActor.assumeIsolated { handler(event) }
                })
        }
        // Seed the actual state as well as observing transitions: an app
        // started while locked must not install the hotkey. Refresh ticks
        // also recover a missed unlock notification.
        handler(Self.currentScreenLockEvent())
        // Weak self: if the adapter deallocates without `stop()`, the next
        // tick ends the task instead of retaining this adapter. The
        // `ObserverTokens` holder still cancels the task and removes the
        // block observers on deallocation; `stop()` remains required for
        // prompt teardown.
        let poll = Task { @MainActor [weak self] in
            while self != nil, !Task.isCancelled {
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
                guard !Task.isCancelled else { return }
                handler(Self.currentScreenLockEvent())
                handler(.refresh)
            }
        }
        tokens.install(
            .init(
                activation: activation, workspaceCenter: workspaceCenter, workspace: workspace,
                distributedCenter: distributedCenter, distributed: distributed, poll: poll))
    }

    func stop() {
        tokens.removeAll()
    }
}
