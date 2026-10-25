import Foundation
import IrisCore

public protocol AudioCaptureLifecycle: AudioCapturing {
    func start() async throws
    func stop() async
    /// Supplies the take ID for failure callbacks. Implementations apply it
    /// only after the previous capture generation has drained.
    func setCaptureGeneration(_ id: Int) async
    /// Device loss while a take is open. Normal `stop()` does not call this.
    /// Stream completion is also how a healthy stop ends, so EOF is not a failure.
    nonisolated func setCaptureFailureHandler(_ handler: @escaping @Sendable (Int, String) -> Void)
}

extension AudioCaptureLifecycle {
    public func setCaptureGeneration(_ id: Int) async {}
}

public protocol ConfigurableTextInserting: TextInserting {
    func update(method: AppSettings.InsertMethod)
    func onNotice(_ handler: ((InsertionNotice) -> Void)?)
}

@MainActor
public protocol HotkeyControlling: HotkeyMonitoring {
    var isMonitoring: Bool { get }
    func update(keyCode: Int)
    func start() -> Bool
    func stop()
    func reconcile()
}

extension HotkeyControlling {
    /// Event-only controllers need no physical-state reconciliation.
    public func reconcile() {}
}

public enum RuntimeSystemEvent: Sendable {
    case refresh, sleep, wake, displaySleep, displayWake
    case sessionInactive, sessionActive, screenLocked, screenUnlocked
}

@MainActor
public protocol SystemEventObserving {
    func start(_ handler: @escaping @MainActor (RuntimeSystemEvent) -> Void)
    func stop()
}

public struct CaptureAuthorization: Sendable {
    public let microphone: @Sendable () -> Bool
    public let accessibility: @Sendable () -> Bool
    public let image: @Sendable () -> Bool

    public init(
        microphone: @escaping @Sendable () -> Bool, accessibility: @escaping @Sendable () -> Bool,
        image: @escaping @Sendable () -> Bool
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.image = image
    }
}

/// All system-facing operations enter through this composition boundary.
/// Tests must supply every port; there are no implicit live fallbacks.
@MainActor
public struct DictationRuntimePorts {
    let audio: any AudioCaptureLifecycle
    let inserter: any ConfigurableTextInserting
    let hotkey: any HotkeyControlling
    let focus: any FocusPort
    let authorization: CaptureAuthorization
    let systemEvents: any SystemEventObserving
    let makeService: DictationOrchestrator.ServiceFactory
    let rewriteFactory: @Sendable (ProviderConfiguration) -> PromptRewrite?
    let shutdownTimeout: Double

    public init(
        audio: any AudioCaptureLifecycle, inserter: any ConfigurableTextInserting,
        hotkey: any HotkeyControlling, focus: any FocusPort, authorization: CaptureAuthorization,
        systemEvents: any SystemEventObserving, makeService: @escaping DictationOrchestrator.ServiceFactory,
        rewriteFactory: @escaping @Sendable (ProviderConfiguration) -> PromptRewrite?, shutdownTimeout: Double = 2
    ) {
        self.audio = audio
        self.inserter = inserter
        self.hotkey = hotkey
        self.focus = focus
        self.authorization = authorization
        self.systemEvents = systemEvents
        self.makeService = makeService
        self.rewriteFactory = rewriteFactory
        self.shutdownTimeout = shutdownTimeout
    }
}
