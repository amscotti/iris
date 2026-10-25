import Foundation

/// A deadline must not join a non-cooperative child on scope exit. The losing
/// operation is cancelled, but its owner must quarantine its resources after a
/// timeout. Cleanup callers deliberately ignore their parent's cancellation.
public enum AsyncDeadline {
    /// The one user-facing timeout sentence, so an ack/finish deadline and
    /// a socket timeout read the same. Keep in sync with the socket
    /// classification copy in `TranscriptionError`.
    public static let timeoutMessage = "The provider didn’t respond in time. Try again."

    public static var timeoutError: TranscriptionError {
        TranscriptionError(kind: .timeout, message: timeoutMessage)
    }

    public static func run<Value: Sendable>(
        seconds: Double, ignoringCancellation: Bool = false,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = DeadlineRace<Value>()
        let priority = Task.currentPriority
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let worker = Task.detached(priority: priority) {
                    do {
                        try Task.checkCancellation()
                        race.resolve(.success(try await operation()))
                    } catch { race.resolve(.failure(error)) }
                }
                let timer = Task.detached(priority: priority) {
                    do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
                    race.resolve(.failure(AsyncDeadline.timeoutError))
                }
                race.own(worker, timer)
            }
        } onCancel: {
            if !ignoringCancellation { race.resolve(.failure(CancellationError())) }
        }
    }

    public static func shutdown(
        seconds: Double = 2, operation: @escaping @Sendable () async -> Void
    ) async -> SessionShutdown {
        do {
            try await run(seconds: seconds, ignoringCancellation: true) { await operation() }
            return .clean
        } catch {
            return .timedOut
        }
    }
}

private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let settled: Result<Value, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let settled { continuation.resume(with: settled) }
    }

    func own(_ worker: Task<Void, Never>, _ timer: Task<Void, Never>) {
        let finished = lock.withLock {
            if result != nil { return true }
            tasks = [worker, timer]
            return false
        }
        if finished {
            worker.cancel()
            timer.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, Error>?, [Task<Void, Never>]) in
            guard self.result == nil else { return (nil, []) }
            self.result = result
            let pending = (continuation, tasks)
            continuation = nil
            tasks = []
            return pending
        }
        for task in pending.1 { task.cancel() }
        pending.0?.resume(with: result)
    }
}
