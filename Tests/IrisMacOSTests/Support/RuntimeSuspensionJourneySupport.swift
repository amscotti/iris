import AppKit
import Foundation
import IrisCore

@testable import IrisMacOS

/// Runtime authorization can change while the Settings model keeps its supplied
/// snapshot. Only these locked, Sendable reads decide whether capture can run.
final class RuntimeJourneyGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var microphone = true
    private var accessibility = true

    func update(microphone: Bool? = nil, accessibility: Bool? = nil) {
        lock.withLock {
            if let microphone { self.microphone = microphone }
            if let accessibility { self.accessibility = accessibility }
        }
    }

    var authorization: CaptureAuthorization {
        CaptureAuthorization(
            microphone: { self.lock.withLock { self.microphone } },
            accessibility: { self.lock.withLock { self.accessibility } }, image: { true })
    }
}

/// Intentionally ignores cancellation: only release or the watchdog retires a
/// parked resource. Entry signals distinguish an actual join from a fast stop.
final class RuntimeJourneyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    let entered = AsyncStream.makeStream(of: Void.self)

    var isReleased: Bool { lock.withLock { released } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                continuations.append(continuation)
                return false
            }
            entered.continuation.yield(())
            if resume { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuations
            continuations = []
            return pending
        }
        for continuation in pending { continuation.resume() }
    }

    func watchdog() -> Task<Void, Never> {
        Task.detached {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self.release()
        }
    }
}

final class RuntimeJourneyClient: TranscriptionClient, Sendable {
    let text: String
    let cancellation: RuntimeJourneyGate?
    let cancelReturned = AsyncStream.makeStream(of: Void.self)
    private let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)

    init(text: String, cancellation: RuntimeJourneyGate?) {
        self.text = text
        self.cancellation = cancellation
    }

    func start(config: ProviderConfiguration) async throws { try Task.checkCancellation() }
    func sendAudio(_ frame: PCMFrame) async throws { try Task.checkCancellation() }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }

    func endAudio() async throws {
        try Task.checkCancellation()
        channel.continuation.yield(.final(text))
        channel.continuation.finish()
    }

    func cancel() async {
        await cancellation?.wait()
        channel.continuation.finish(throwing: CancellationError())
        cancelReturned.continuation.yield(())
    }
}

/// Each reservation gets its own channel. Reusing a cancelled mock would hide
/// take-ID or stream-generation mistakes in cancel/complete/cancel journeys.
final class RuntimeJourneyServices: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [RuntimeJourneyClient] = []
    private let firstCancellation: RuntimeJourneyGate?

    init(firstCancellation: RuntimeJourneyGate?) { self.firstCancellation = firstCancellation }

    var count: Int { lock.withLock { clients.count } }
    var first: RuntimeJourneyClient? { lock.withLock { clients.first } }

    func makeService() -> TranscriptionService {
        let client = lock.withLock {
            let client = RuntimeJourneyClient(
                text: "journey take \(clients.count + 1)",
                cancellation: clients.isEmpty ? firstCancellation : nil)
            clients.append(client)
            return client
        }
        return TranscriptionService(client: client)
    }
}

final class RuntimeJourneyParkedCapture: AudioCaptureLifecycle, Sendable {
    let base: RuntimeTestAudio
    let stopping: RuntimeJourneyGate
    let stopReturned = AsyncStream.makeStream(of: Void.self)

    init(base: RuntimeTestAudio, stopping: RuntimeJourneyGate) {
        self.base = base
        self.stopping = stopping
    }

    func setCaptureGeneration(_ id: Int) async { await base.setCaptureGeneration(id) }
    func start() async throws { try await base.start() }
    func frames() -> AsyncStream<PCMFrame> { base.frames() }
    nonisolated func setCaptureFailureHandler(_ handler: @escaping @Sendable (Int, String) -> Void) {
        base.setCaptureFailureHandler(handler)
    }

    func stop() async {
        await base.stop()
        await stopping.wait()
        stopReturned.continuation.yield(())
    }
}

private struct RuntimeJourneySignalEnded: Error {
    let signal: String
}

func runtimeJourneyNext<Value: Sendable>(_ stream: AsyncStream<Value>, signal: String) async throws -> Value {
    try await AsyncDeadline.run(seconds: 5) {
        var input = stream.makeAsyncIterator()
        guard let value = await input.next() else { throw RuntimeJourneySignalEnded(signal: signal) }
        return value
    }
}

@MainActor
final class RuntimeSuspensionJourney {
    let fixture: RuntimeFixture
    let backend: TestHotkeyEvents
    let grants: RuntimeJourneyGrants
    let services: RuntimeJourneyServices
    let environment: AppEnvironment
    let parkedCapture: RuntimeJourneyParkedCapture?
    private(set) var notices: [DictationNotice] = []
    private var snapshotReceivers: [UUID: @MainActor (DictationSnapshot) -> Void] = [:]

    var runtime: DictationRuntime { environment.runtime }

    private init(
        fixture: RuntimeFixture, backend: TestHotkeyEvents, grants: RuntimeJourneyGrants,
        services: RuntimeJourneyServices, environment: AppEnvironment, parkedCapture: RuntimeJourneyParkedCapture?
    ) {
        self.fixture = fixture
        self.backend = backend
        self.grants = grants
        self.services = services
        self.environment = environment
        self.parkedCapture = parkedCapture
    }

    static func start(
        providerCancellation: RuntimeJourneyGate?, captureStop: RuntimeJourneyGate?, shutdownTimeout: Double
    ) async throws -> RuntimeSuspensionJourney {
        let fixture = RuntimeFixture()
        let backend = TestHotkeyEvents()
        let monitor = GlobalHotkeyMonitor(keyCode: 61, backend: backend)
        let grants = RuntimeJourneyGrants()
        let services = RuntimeJourneyServices(firstCancellation: providerCancellation)
        let supplied = fixture.ports(
            hotkey: monitor, service: { _ in services.makeService() }, timeout: shutdownTimeout,
            authorization: grants.authorization)
        let parkedCapture = captureStop.map { RuntimeJourneyParkedCapture(base: fixture.audio, stopping: $0) }
        let audio: any AudioCaptureLifecycle
        if let parkedCapture { audio = parkedCapture } else { audio = supplied.audio }
        let ports = DictationRuntimePorts(
            audio: audio, inserter: supplied.inserter, hotkey: supplied.hotkey,
            focus: supplied.focus, authorization: supplied.authorization, systemEvents: supplied.systemEvents,
            makeService: supplied.makeService, rewriteFactory: supplied.rewriteFactory,
            shutdownTimeout: supplied.shutdownTimeout)
        let store = TestEnvironment()
        try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
        var defaults = AppSettings.defaults
        defaults.hotkey = HotkeyConfiguration(keyCode: 61, mode: .hold)
        defaults.trailingSpace = true
        defaults.trailingNewline = false
        // Deliberately fixed fake UI permissions; assertions use the runtime's
        // independently mutable authorization, never the host's TCC database.
        let environment = store.make(
            permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
            runtimePorts: ports, defaults: defaults)
        do {
            try await AsyncDeadline.run(seconds: 5) { await environment.start() }
        } catch {
            providerCancellation?.release()
            captureStop?.release()
            await environment.stop()
            throw error
        }
        let journey = RuntimeSuspensionJourney(
            fixture: fixture, backend: backend, grants: grants, services: services,
            environment: environment, parkedCapture: parkedCapture)
        journey.observe()
        return journey
    }

    private func observe() {
        let originalNotice = runtime.onNotice
        runtime.onNotice = { [weak self] notice in
            originalNotice?(notice)
            self?.notices.append(notice)
        }
        let originalSnapshot = runtime.onSnapshot
        runtime.onSnapshot = { [weak self] snapshot in
            originalSnapshot?(snapshot)
            guard let self else { return }
            for receiver in Array(self.snapshotReceivers.values) { receiver(snapshot) }
        }
    }

    func press() {
        backend.keyPressed = true
        backend.globalHandlers.first?(
            .init(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue))
    }

    func release() {
        backend.keyPressed = false
        backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61))
    }

    func nextSnapshot(
        matching predicate: @escaping @MainActor (DictationSnapshot) -> Bool,
        during operation: @MainActor () async throws -> Void
    ) async throws -> DictationSnapshot {
        let channel = AsyncStream.makeStream(of: DictationSnapshot.self)
        let token = UUID()
        snapshotReceivers[token] = { if predicate($0) { channel.continuation.yield($0) } }
        defer {
            snapshotReceivers.removeValue(forKey: token)
            channel.continuation.finish()
        }
        try await operation()
        return try await runtimeJourneyNext(channel.stream, signal: "matching runtime snapshot")
    }

    @discardableResult
    func beginRecordedTake() async throws -> DictationSnapshot {
        try await nextSnapshot(
            matching: {
                if case .recording(let level) = $0.state { return level > 0 }
                return false
            },
            during: {
                self.press()
                // Consume exactly one start per take. Never leave a buffered old
                // audio.started event to masquerade as the next take's startup.
                _ = try await runtimeJourneyNext(self.fixture.audio.started.stream, signal: "fresh capture start")
                await self.fixture.audio.emitFrame()
            })
    }

    func releaseAndWaitForInsertion() async throws -> String {
        release()
        return try await runtimeJourneyNext(fixture.inserter.inserted.stream, signal: "transcript insertion")
    }

    func waitForCleanup() async throws -> SessionShutdown {
        let runtime = self.runtime
        return try await AsyncDeadline.run(seconds: 5) { await runtime.waitForCleanup() }
    }

    /// The inserter receipt precedes completeTake's final actor hop. Join that
    /// tail before the next physical press; do not turn a completion race into
    /// a flaky busy refusal. The same orchestrator and take-ID sequence survive.
    func joinInsertionAndRestartInput() async throws {
        let runtime = self.runtime
        try await AsyncDeadline.run(seconds: 5) { await runtime.stop() }
        try await AsyncDeadline.run(seconds: 5) { await runtime.start() }
    }

    /// An executor/event checkpoint for queued UI deliveries, not a time sleep.
    func mainActorCheckpoint() async throws {
        let signal = AsyncStream.makeStream(of: Void.self)
        let queued = Task { @MainActor in
            signal.continuation.yield(())
            signal.continuation.finish()
        }
        defer { queued.cancel() }
        _ = try await runtimeJourneyNext(signal.stream, signal: "main-actor checkpoint")
    }
}

@MainActor
func withRuntimeSuspensionJourney(
    providerCancellation: RuntimeJourneyGate? = nil, captureStop: RuntimeJourneyGate? = nil,
    shutdownTimeout: Double = 2, operation: @MainActor (RuntimeSuspensionJourney) async throws -> Void
) async throws {
    let gates = [providerCancellation, captureStop].compactMap { $0 }
    let watchdogs = gates.map { $0.watchdog() }
    defer {
        for watchdog in watchdogs { watchdog.cancel() }
        for gate in gates { gate.release() }
    }
    let journey = try await RuntimeSuspensionJourney.start(
        providerCancellation: providerCancellation, captureStop: captureStop, shutdownTimeout: shutdownTimeout)
    do {
        try await operation(journey)
    } catch {
        for gate in gates { gate.release() }
        await journey.environment.stop()
        throw error
    }
    for gate in gates { gate.release() }
    await journey.environment.stop()
}
