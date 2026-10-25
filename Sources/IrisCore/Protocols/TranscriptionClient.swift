import Foundation

/// Provider-agnostic speech-to-text session.
///
/// One client instance handles one utterance: start a session, stream audio
/// frames, and end audio on release. Exactly one consumer observes events for
/// the whole take, including while recording. End audio and cancellation must
/// unblock the event stream. A client owns its reader and serialized writer.
///
/// Cancellation is required, not optional: every provider must close its
/// transport and unblock pending reads/writes without completing a
/// transcript. The service enforces a bounded shutdown deadline on top of
/// this contract so a hung provider cannot pause input indefinitely.
///
/// Concurrency rule: the caller serializes `start`/`sendAudio`/`endAudio`
/// (no overlapping calls); `cancel()` is the exception — it is idempotent,
/// callable concurrently with anything, and must return promptly.
/// `events()` may be obtained once per take and has exactly one consumer.
public protocol TranscriptionClient: Sendable {
    func start(config: ProviderConfiguration) async throws
    func sendAudio(_ frame: PCMFrame) async throws
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error>
    func endAudio() async throws
    /// Abort without completing a transcript. Must be explicit and
    /// cooperative: close transports and return promptly.
    func cancel() async
}

extension TranscriptionClient {
    /// Convenience for one-shot consumers. The service uses events() from
    /// startup instead; never consume this and events() on the same take.
    /// Subscribe before `endAudio` so queued events survive the close.
    /// `endAudio` stays concurrent so finals produced by the close are still observed.
    public func finish() -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let upstream = events()
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let worker = Task {
                var iterator = upstream.makeAsyncIterator()
                let ending = Task { try await self.endAudio() }
                do {
                    while let event = try await iterator.next() { continuation.yield(event) }
                    try await ending.value
                    continuation.finish()
                } catch {
                    ending.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                worker.cancel()
                // Abandoned one-shot takes must not leak transports: if the
                // consumer went away, abort the session explicitly.
                if case .cancelled = termination {
                    Task { await self.cancel() }
                }
            }
        }
    }
}

/// How a take's transport settled. Produced by `TranscriptionService`
/// teardown, not by `TranscriptionClient` methods; declared here so the
/// whole session contract reads in one place.
public enum SessionShutdown: Sendable, Equatable {
    case clean
    case timedOut
}

public enum TranscriptionOutcome: Sendable, Equatable {
    case completed(String)
    case failed(TranscriptionError)
    case cancelled
}
// Note: `TranscriptionOutcome` is produced by `TranscriptionService.finish()`
// (which retains the terminal result independently of UI state), not by
// `TranscriptionClient` methods. Kept adjacent for discoverability.
