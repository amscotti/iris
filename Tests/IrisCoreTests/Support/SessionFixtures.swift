import Foundation
import IrisCore

final class TestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func update<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&value) } }
}

/// Unlike Task.sleep/AsyncStream.next, this deliberately ignores cancellation.
/// Tests always release it, with a watchdog to keep broken implementations finite.
/// The gate itself stays non-cooperative on purpose (hanging-cancel tests park
/// here through their shutdown deadline); cooperative cancellation lives in the
/// client doubles, which check `Task.isCancelled` around gate waits.
final class ManualGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let entered = AsyncStream.makeStream(of: Void.self)
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
    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
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

final class ControlledClient: TranscriptionClient, Sendable {
    let startGate: ManualGate?
    let sendGate: ManualGate?
    let sendFailure: TranscriptionError?
    let starts = TestValue(0)
    let cancels = AsyncStream.makeStream(of: Void.self)
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    init(start: ManualGate? = nil, send: ManualGate? = nil, failSend: Bool = false) {
        startGate = start
        sendGate = send
        sendFailure = failSend ? TranscriptionError(kind: .network, message: "audio failure") : nil
    }
    func start(config: ProviderConfiguration) async throws {
        starts.update { $0 += 1 }
        try Task.checkCancellation()
        await startGate?.wait()
        try Task.checkCancellation()
    }
    func sendAudio(_ frame: PCMFrame) async throws {
        try Task.checkCancellation()
        await sendGate?.wait()
        try Task.checkCancellation()
        if let sendFailure { throw sendFailure }
    }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        channel.continuation.yield(.final("success"))
        channel.continuation.finish()
    }
    /// Prompt and idempotent per the protocol: records the call, fails the
    /// channel, and returns without parking. Arrival is signalled through
    /// `cancels`, so nothing can stall shutdown. Tests for hung-provider
    /// shutdown use `HangingCancelClient` below instead.
    func cancel() async {
        cancels.continuation.yield(())
        channel.continuation.finish(throwing: CancellationError())
    }
}

/// Deliberately non-cooperative double for shutdown-deadline tests: parks in
/// `cancel` until its gate is released, modelling a hung provider. Do not use
/// it where the prompt-cancel contract is under test.
final class HangingCancelClient: TranscriptionClient, Sendable {
    let gate: ManualGate?
    let cancels = AsyncStream.makeStream(of: Void.self)
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    init(cancel gate: ManualGate? = nil) { self.gate = gate }
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        channel.continuation.yield(.final("success"))
        channel.continuation.finish()
    }
    func cancel() async {
        cancels.continuation.yield(())
        await gate?.wait()
        channel.continuation.finish(throwing: CancellationError())
    }
}
