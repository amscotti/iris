#if DEBUG
    import Foundation
    import IrisCore

    /// Scripted provider for tests and offline demos: replays partials, then a final.
    ///
    /// Confined to serial single-owner use by the orchestrator, like the
    /// production clients.
    public final class MockTranscriptionClient: TranscriptionClient, @unchecked Sendable {
        public struct Script: Sendable, Equatable {
            public var partials: [String]
            public var final: String

            public init(partials: [String] = ["hello", "hello world"], final: String = "hello world") {
                self.partials = partials
                self.final = final
            }

            public static var emptyFinal: Script { Script(partials: [], final: "") }
        }

        private let script: Script
        private let autoFinal: Bool
        private let lock = NSLock()
        private enum Phase { case idle, streaming, ended, cancelled, failed }
        private var phase: Phase = .idle
        private var startedConfigs: [ProviderConfiguration] = []
        private var receivedFrames: [PCMFrame] = []
        private var finishCalls = 0
        private var terminalError: Error?
        private var channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)

        /// When set, finish() fails with this error instead of replaying.
        public var finishError: Error? {
            get { lock.withLock { _finishError } }
            set { lock.withLock { _finishError = newValue } }
        }
        private var _finishError: Error?

        public init(script: Script = Script(), autoFinal: Bool = true) {
            self.script = script
            self.autoFinal = autoFinal
        }

        public func start(config: ProviderConfiguration) async throws {
            try Task.checkCancellation()
            // Like SessionDriver (guard phase == .idle), an overlapping second
            // start fails. Unlike the single-utterance production clients, the
            // mock stays reusable across takes: a start after a terminal state
            // resets with a fresh channel so one instance can serve consecutive
            // presses in tests. The abandoned continuation is finished so the
            // prior events() consumer never leaks.
            let previous = try lock.withLock {
                () -> AsyncThrowingStream<TranscriptionEvent, Error>.Continuation? in
                switch phase {
                case .streaming:
                    throw CancellationError()
                case .idle:
                    phase = .streaming
                    startedConfigs.append(config)
                    return nil
                case .ended, .cancelled, .failed:
                    let old = channel.continuation
                    channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
                    phase = .streaming
                    terminalError = nil
                    startedConfigs.append(config)
                    return old
                }
            }
            previous?.finish()
        }

        public func sendAudio(_ frame: PCMFrame) async throws {
            try Task.checkCancellation()
            let active = lock.withLock { phase == .streaming }
            guard active else {
                throw TranscriptionError(kind: .invalidState, message: "Audio sent outside an active session.")
            }
            lock.withLock { receivedFrames.append(frame) }
        }

        public func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { lock.withLock { channel.stream } }

        public func endAudio() async throws {
            try Task.checkCancellation()
            struct Snapshot {
                var continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
                var partials: [String]
                var final: String
                var autoFinal: Bool
                var failure: Error?
            }
            let snapshot: Snapshot? = lock.withLock {
                finishCalls += 1
                if phase == .cancelled || phase == .failed {
                    return nil
                }
                guard phase == .streaming else {
                    return Snapshot(
                        continuation: channel.continuation, partials: [], final: "",
                        autoFinal: true,
                        failure: TranscriptionError(
                            kind: .invalidState, message: "Finish called outside an active session."))
                }
                phase = .ended
                return Snapshot(
                    continuation: channel.continuation, partials: script.partials,
                    final: script.final, autoFinal: autoFinal, failure: _finishError)
            }
            guard let snapshot else {
                let terminal = lock.withLock { terminalError }
                if let terminal { throw terminal }
                throw CancellationError()
            }
            if let failure = snapshot.failure {
                lock.withLock {
                    phase = .failed
                    terminalError = failure
                }
                snapshot.continuation.finish(throwing: failure)
                throw failure
            }
            // Delivery happens outside the lock so a continuation callback that
            // re-enters the client (e.g. finish()'s onTermination -> cancel())
            // cannot deadlock on lock re-entrancy.
            for partial in snapshot.partials {
                snapshot.continuation.yield(.partial(partial))
            }
            if snapshot.autoFinal {
                // Empty finals are a real server shape: production codecs
                // surface them, and Script.emptyFinal mirrors that path.
                snapshot.continuation.yield(.final(snapshot.final))
            }
            snapshot.continuation.finish()
        }

        public func cancel() async {
            let continuation = lock.withLock { () -> AsyncThrowingStream<TranscriptionEvent, Error>.Continuation? in
                guard phase == .streaming || phase == .idle else { return nil }
                phase = .cancelled
                terminalError = CancellationError()
                return channel.continuation
            }
            continuation?.finish(throwing: CancellationError())
        }

        // MARK: - Inspection

        public var receivedFrameCount: Int { lock.withLock { receivedFrames.count } }
        public var startCallCount: Int { lock.withLock { startedConfigs.count } }
        public var finishCallCount: Int { lock.withLock { finishCalls } }
        public var lastConfig: ProviderConfiguration? { lock.withLock { startedConfigs.last } }
    }

#endif
