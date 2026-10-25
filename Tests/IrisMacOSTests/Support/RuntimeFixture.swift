import Foundation
import IrisCore
import IrisProviders

@testable import IrisMacOS

actor RuntimeTestAudio: AudioCaptureLifecycle {
    private let framesHost = RestartableStream<PCMFrame>()
    private(set) var starts = 0
    private(set) var stops = 0
    private var captureGeneration = 0
    private var pendingCaptureGeneration = 0
    private let captureFailureLock = NSLock()
    private nonisolated(unsafe) var captureFailureHandler: (@Sendable (Int, String) -> Void)?
    nonisolated let started = AsyncStream.makeStream(of: Void.self)
    nonisolated let stopped = AsyncStream.makeStream(of: Void.self)
    func setCaptureGeneration(_ id: Int) async { pendingCaptureGeneration = id }
    func start() async throws {
        captureGeneration = pendingCaptureGeneration
        starts += 1
        framesHost.rotate()
        started.continuation.yield(())
    }
    func stop() async {
        stops += 1
        framesHost.finish()
        stopped.continuation.yield(())
    }
    func emitFrame() { framesHost.currentContinuation.yield(PCMFrame(samples: [1000, -1000])) }
    nonisolated func frames() -> AsyncStream<PCMFrame> { framesHost.currentStream }
    nonisolated func setCaptureFailureHandler(_ handler: @escaping @Sendable (Int, String) -> Void) {
        captureFailureLock.withLock { captureFailureHandler = handler }
    }
    /// Simulates device loss while a take is open, through the same
    /// out-of-band handler the live capturer uses.
    func failCapture(_ message: String, takeID: Int? = nil) {
        let handler = captureFailureLock.withLock { captureFailureHandler }
        handler?(takeID ?? captureGeneration, message)
    }
}

final class RuntimeTestInserter: ConfigurableTextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTargets: [InsertionTargetSnapshot?] = []
    let inserted = AsyncStream.makeStream(of: String.self)
    var targets: [InsertionTargetSnapshot?] { lock.withLock { storedTargets } }
    func update(method: AppSettings.InsertMethod) {}
    func onNotice(_ handler: ((InsertionNotice) -> Void)?) {}
    func insert(_ text: String) { insert(text, target: nil) }
    func insert(_ text: String, target: InsertionTargetSnapshot?) {
        lock.withLock { storedTargets.append(target) }
        inserted.continuation.yield(text)
    }
}

final class RuntimeTestFocus: FocusPort, @unchecked Sendable {
    private let lock = NSLock()
    private var target = InsertionTarget(pid: 1, bundleID: "fixture.first")
    func update(pid: Int32) { lock.withLock { target.pid = pid } }
    func isProcessTrusted() -> Bool { true }
    func focusedIsSecure() -> Bool { false }
    func currentTarget() -> InsertionTarget? { lock.withLock { target } }
}

@MainActor
final class RuntimeTestKeys: HotkeyControlling {
    private nonisolated let host = RestartableStream<HotkeyEvent>()
    private(set) var isMonitoring = false
    func update(keyCode: Int) {}
    func start() -> Bool {
        host.rotate()
        isMonitoring = true
        return true
    }
    func stop() {
        isMonitoring = false
        host.finish()
    }
    nonisolated func events() -> AsyncStream<HotkeyEvent> { host.currentStream }
    func emit(_ event: HotkeyEvent) { host.currentContinuation.yield(event) }
}

@MainActor
final class RuntimeTestSystemEvents: SystemEventObserving {
    private var handler: (@MainActor (RuntimeSystemEvent) -> Void)?
    func start(_ handler: @escaping @MainActor (RuntimeSystemEvent) -> Void) { self.handler = handler }
    func stop() { handler = nil }
    func emit(_ event: RuntimeSystemEvent) { handler?(event) }
}

@MainActor
struct RuntimeFixture {
    let audio = RuntimeTestAudio()
    let inserter = RuntimeTestInserter()
    let focus = RuntimeTestFocus()
    let keys = RuntimeTestKeys()
    let systemEvents = RuntimeTestSystemEvents()

    /// Wait for a level from delivered audio, rather than a provider's initial
    /// recording status that can precede the startup task's final actor hop.
    func beginRecordedTake(in environment: AppEnvironment) async throws {
        let ready = AsyncStream.makeStream(of: Void.self)
        let original = environment.runtime.onSnapshot
        environment.runtime.onSnapshot = { snapshot in
            original?(snapshot)
            if case .recording(let level) = snapshot.state, level > 0 { ready.continuation.yield(()) }
        }
        defer { environment.runtime.onSnapshot = original }
        keys.emit(.pressed)
        try await AsyncDeadline.run(seconds: 5) {
            var starts = audio.started.stream.makeAsyncIterator()
            _ = await starts.next()
            await audio.emitFrame()
            var recording = ready.stream.makeAsyncIterator()
            _ = await recording.next()
        }
    }

    func ports(
        microphone: Bool = true, accessibility: Bool = true, hotkey: (any HotkeyControlling)? = nil,
        service: @escaping DictationOrchestrator.ServiceFactory = { _ in
            TranscriptionService(client: MockTranscriptionClient())
        },
        rewrite: @escaping @Sendable (ProviderConfiguration) -> PromptRewrite? = { _ in nil },
        timeout: Double = 2, authorization: CaptureAuthorization? = nil
    ) -> DictationRuntimePorts {
        DictationRuntimePorts(
            audio: audio, inserter: inserter, hotkey: hotkey ?? keys, focus: focus,
            authorization: authorization
                ?? CaptureAuthorization(
                    microphone: { microphone }, accessibility: { accessibility }, image: { true }),
            systemEvents: systemEvents, makeService: service, rewriteFactory: rewrite, shutdownTimeout: timeout)
    }
}
