import Foundation

/// One restartable generation of a never-ending element stream.
///
/// A plain `AsyncStream` delivers each value to exactly one iterator, so a
/// consumer that is cancelled while suspended keeps absorbing values meant
/// for the next consumer. Capture restarts every press while its consumers
/// churn per press, so sharing one stream across presses starves the second
/// press of frames. This box fixes the lifecycle: `rotate()` ends the
/// previous generation (suspended consumers terminate instead of lingering)
/// and opens a fresh stream for the next press; `finish()` ends the current
/// generation without replacement.
final class RestartableStream<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: AsyncStream<Element>
    private var continuation: AsyncStream<Element>.Continuation
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    /// - Parameter bufferingPolicy: Defaults to `.unbounded`: hotkey edges
    ///   and audio frames must not be dropped (a coalesced press+release
    ///   loses a dictation). A specific policy can still be requested, but
    ///   `rotate()` is the mechanism that discards stale generations.
    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        let (stream, continuation) = AsyncStream<Element>.makeStream(
            of: Element.self, bufferingPolicy: bufferingPolicy)
        self.stream = stream
        self.continuation = continuation
        self.bufferingPolicy = bufferingPolicy
    }

    /// The live stream of the current generation.
    var currentStream: AsyncStream<Element> {
        lock.withLock { stream }
    }

    /// The continuation feeding the current generation. The producer captures
    /// it when a generation starts.
    var currentContinuation: AsyncStream<Element>.Continuation {
        lock.withLock { continuation }
    }

    /// Ends the current generation and opens a fresh stream for the next
    /// one. Safe to call when no generation is live.
    func rotate() {
        lock.withLock {
            continuation.finish()
            let (next, nextContinuation) = AsyncStream<Element>.makeStream(
                of: Element.self, bufferingPolicy: bufferingPolicy)
            stream = next
            continuation = nextContinuation
        }
    }

    /// Ends the current generation without replacement. Suspended consumers
    /// terminate; later yields are dropped until the next `rotate()`. Safe to
    /// call more than once.
    func finish() {
        lock.withLock { continuation.finish() }
    }
}
