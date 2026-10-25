import AppKit
import CoreGraphics
import IrisCore
import os

/// AppKit delivers global events asynchronously as copies. Iris is never in
/// another application's input-delivery path, even if Iris's UI is stalled.
/// The local observer also returns every event unchanged.
@MainActor
public final class GlobalHotkeyMonitor: HotkeyControlling {
    public static let rightOptionKeyCode = HotkeyConfiguration.defaultKeyCode

    /// Edges are lossless per generation. `rotate()` drops stale generations.
    private nonisolated let eventsHost = RestartableStream<HotkeyEvent>()
    private let backend: any HotkeyEventMonitoring
    private var edges: HotkeyEdgeState
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var generation = 0
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "hotkey")

    public convenience init(keyCode: Int = rightOptionKeyCode) {
        self.init(keyCode: keyCode, backend: AppKitHotkeyEvents())
    }

    init(keyCode: Int = rightOptionKeyCode, backend: any HotkeyEventMonitoring) {
        self.backend = backend
        // Lost key-ups are reconciled against real keyboard state. The probe
        // runs inline where edges are handled, on the main actor.
        self.edges = HotkeyEdgeState(keyCode: keyCode) { [backend] code in
            MainActor.assumeIsolated { backend.isKeyPressed(code) }
        }
    }

    public nonisolated func events() -> AsyncStream<HotkeyEvent> { eventsHost.currentStream }
    public var isMonitoring: Bool { globalMonitor != nil && localMonitor != nil }

    public func update(keyCode: Int) {
        guard keyCode != edges.keyCode else { return }
        let held = isMonitoring && backend.isKeyPressed(keyCode)
        if let release = edges.retarget(keyCode, requireRelease: held) {
            eventsHost.currentContinuation.yield(release)
        }
    }

    /// Polls physical state only while observers are active, closing a hold
    /// whose key-up was lost even when no later keyboard event arrives.
    public func reconcile() {
        guard isMonitoring, let edge = edges.reconcile() else { return }
        eventsHost.currentContinuation.yield(edge)
    }

    @discardableResult
    public func start() -> Bool {
        if isMonitoring { return true }
        generation += 1
        let current = generation
        eventsHost.rotate()
        // A held key across a permission dialog must be released before it
        // can start another recording. The physical-state probe also runs
        // inline from event callbacks while a press is active or a release
        // is awaited, to reconcile edges lost to a dropout.
        edges.reset(requireRelease: backend.isKeyPressed(edges.keyCode))
        globalMonitor = backend.addGlobal { [weak self] event in
            self?.receive(event, generation: current)
        }
        localMonitor = backend.addLocal { [weak self] event in
            self?.receive(event, generation: current)
        }
        guard isMonitoring else {
            stop()
            logger.notice("Passive shortcut monitoring unavailable; check Accessibility access.")
            return false
        }
        logger.info("Passive shortcut observers installed.")
        return true
    }

    public func stop() {
        generation += 1
        let monitors = [globalMonitor, localMonitor].compactMap { $0 }
        globalMonitor = nil
        localMonitor = nil
        edges.reset()
        for monitor in monitors { backend.remove(monitor) }
        eventsHost.finish()
        if !monitors.isEmpty { logger.info("Passive shortcut observers stopped.") }
    }

    private func receive(_ event: HotkeyInput, generation: Int) {
        guard generation == self.generation, isMonitoring else { return }
        if let edge = edges.handle(event) { eventsHost.currentContinuation.yield(edge) }
    }

    deinit {
        eventsHost.finish()
    }
}

/// Injectable so unit tests exercise observer lifetimes without installing
/// global monitors or querying the real keyboard.
@MainActor
protocol HotkeyEventMonitoring {
    func addGlobal(_ handler: @escaping @MainActor (HotkeyInput) -> Void) -> Any?
    func addLocal(_ handler: @escaping @MainActor (HotkeyInput) -> Void) -> Any?
    func remove(_ monitor: Any)
    func isKeyPressed(_ keyCode: Int) -> Bool
}

/// Removes an installed `NSEvent` monitor once, either on explicit `remove()`
/// or if the owning `GlobalHotkeyMonitor` deallocates without `stop()`.
private final class AppKitMonitorToken {
    private var monitor: Any?

    init(_ monitor: Any) {
        self.monitor = monitor
    }

    func remove() {
        guard let monitor else { return }
        self.monitor = nil
        NSEvent.removeMonitor(monitor)
    }

    deinit {
        // Deallocation can happen on any thread, but NSEvent monitor
        // removal belongs on the main thread: hop there when needed.
        guard let monitor else { return }
        if Thread.isMainThread {
            NSEvent.removeMonitor(monitor)
        } else {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                NSEvent.removeMonitor(monitor)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

@MainActor
private struct AppKitHotkeyEvents: HotkeyEventMonitoring {
    private let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]

    func addGlobal(_ handler: @escaping @MainActor (HotkeyInput) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            guard let input = HotkeyInput(event: event) else { return }
            MainActor.assumeIsolated { handler(input) }
        }.map(AppKitMonitorToken.init)
    }

    func addLocal(_ handler: @escaping @MainActor (HotkeyInput) -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            HotkeyEventForwarding.passThrough(event, handler: handler)
        }.map(AppKitMonitorToken.init)
    }

    func remove(_ monitor: Any) {
        if let token = monitor as? AppKitMonitorToken {
            token.remove()
        } else {
            NSEvent.removeMonitor(monitor)
        }
    }

    func isKeyPressed(_ keyCode: Int) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(clamping: keyCode))
    }
}

enum HotkeyEventForwarding {
    /// Only a Sendable snapshot enters the actor; the NSEvent always stays
    /// in its original dispatch context and is returned unchanged.
    static func passThrough(_ event: NSEvent, handler: @MainActor (HotkeyInput) -> Void) -> NSEvent {
        if let input = HotkeyInput(event: event) {
            MainActor.assumeIsolated { handler(input) }
        }
        return event
    }
}
