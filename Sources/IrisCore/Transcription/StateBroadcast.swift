import Foundation

/// Call send/subscribe from the owning actor. Termination may arrive from any
/// executor. Live UI uses latest-only snapshots; explicit state/terminal event
/// subscriptions are lossless and removed when the consumer terminates.
final class StateBroadcast<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]

    var count: Int { lock.withLock { subscribers.count } }

    func stream(
        initial: Value? = nil, buffering: AsyncStream<Value>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: buffering) { continuation in
            lock.withLock { subscribers[id] = continuation }
            if let initial { continuation.yield(initial) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func send(_ value: Value) {
        let current = lock.withLock { Array(subscribers.values) }
        for continuation in current { continuation.yield(value) }
    }
}
