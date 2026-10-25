import Foundation

/// A single terminal result, separate from any lossy UI snapshot stream.
final class AsyncResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(with: result) }
    }

    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let settled: Result<Value, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let result { return result }
                    waiters[id] = continuation
                    return nil
                }
                if let settled { continuation.resume(with: settled) }
            }
        } onCancel: {
            let pending = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            pending?.resume(throwing: CancellationError())
        }
    }
}
