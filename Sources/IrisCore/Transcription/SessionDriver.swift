import Foundation

/// A provider's wire policy, confined to the session actor. Accumulators are
/// ordinary values; only this session's reader ever mutates the codec.
public protocol SpeechSessionCodec: Sendable {
    var handshake: TransportMessage? { get }
    var endMarker: TransportMessage { get }
    var completesOnClose: Bool { get }
    func isReady(_ message: TransportMessage) -> Bool
    mutating func decode(_ message: TransportMessage) -> TranscriptionEvent?
}

/// One reader, a serialized writer, and explicit readiness/terminal results
/// per take. Errors are decoded continuously, rather than buffered until release.
public actor SessionDriver {
    private enum Phase { case idle, starting, streaming, ending, completed, failed, cancelled }
    private let transport: any ByteStream
    private let ackTimeout: Double
    private let finishTimeout: Double
    /// Hard bound on one streaming session. Meta documents a 60-minute
    /// realtime limit; end past it with an explicit limit error instead of
    /// letting the forced close discard the take as a generic disconnect.
    public static let maxSessionSeconds: Double = 55 * 60
    private let maxSessionSeconds: Double
    private let uptime: @Sendable () -> Double
    /// Monotonic uptime, so a wall-clock adjustment cannot fire the cap.
    private var streamingSince: Double?
    private var phase: Phase = .idle
    private var codec: (any SpeechSessionCodec)?
    private let ready = AsyncResult<Void>()
    private let terminal = AsyncResult<Void>()
    private let stream: AsyncThrowingStream<TranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    private var reader: Task<Void, Never>?
    private var connection: Task<Void, Error>?
    private var writer: Task<Void, Error>?
    private var cleanup: Task<Void, Never>?

    public init(
        transport: any ByteStream, ackTimeout: Double, finishTimeout: Double,
        maxSessionSeconds: Double = SessionDriver.maxSessionSeconds,
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport
        self.ackTimeout = ackTimeout
        self.finishTimeout = finishTimeout
        self.maxSessionSeconds = maxSessionSeconds
        self.uptime = uptime
        // Event delivery is lossless up to this explicit limit. Overflow fails
        // the take instead of silently dropping a turn or a terminal event.
        let pair = AsyncThrowingStream.makeStream(
            of: TranscriptionEvent.self, throwing: Error.self, bufferingPolicy: .bufferingOldest(256))
        stream = pair.stream
        continuation = pair.continuation
    }

    public nonisolated func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { stream }

    public func start(codec: any SpeechSessionCodec) async throws {
        guard phase == .idle else { throw CancellationError() }
        phase = .starting
        self.codec = codec
        let opening = Task { [transport] in try await transport.connect() }
        connection = opening
        do {
            try await AsyncDeadline.run(seconds: ackTimeout) {
                try await opening.value
                try await self.openReaderAndHandshake()
                try await self.ready.value()
            }
            guard phase != .cancelled, !Task.isCancelled else { throw CancellationError() }
        } catch {
            fail(error)
            _ = await AsyncDeadline.shutdown { await self.waitForCleanup() }
            throw error
        }
    }

    private func openReaderAndHandshake() async throws {
        guard phase == .starting, !Task.isCancelled else { throw CancellationError() }
        if let handshake = codec?.handshake {
            do { try await write(handshake) } catch {
                throw TranscriptionError(
                    kind: .network, message: "Handshake write failed: \(error.localizedDescription)")
            }
        }
        guard phase == .starting, !Task.isCancelled else { throw CancellationError() }
        let incoming = transport.messages()
        reader = Task { [weak self] in
            do {
                for try await message in incoming {
                    guard !Task.isCancelled, let self else { return }
                    if !(await self.receive(message)) { return }
                }
                await self?.closed()
            } catch {
                // A normal server close after the end marker is the documented
                // completion signal for completesOnClose codecs (Meta
                // ENDPOINTING/DIARIZATION). Abnormal drops remain failures.
                if let failure = error as? TranscriptionError, failure.kind == .serverClosed,
                    failure.isNormalClosure, await self?.phase == .ending,
                    await self?.codec?.completesOnClose == true
                {
                    await self?.closed()
                } else {
                    await self?.fail(error)
                }
            }
        }
    }

    public func sendAudio(_ frame: PCMFrame) async throws {
        guard phase == .streaming else {
            throw TranscriptionError(kind: .invalidState, message: "Audio sent outside an active session.")
        }
        if let since = streamingSince, uptime() - since >= maxSessionSeconds {
            let minutes = Int((maxSessionSeconds / 60).rounded())
            let error = TranscriptionError(
                kind: .streamLimit,
                message: "Speech session reached the \(minutes)-minute limit. Start a new take to continue.")
            fail(error)
            throw error
        }
        do { try await write(.binary(frame.asData())) } catch {
            try await reconcileWriteFailure(Self.classifiedWriteFailure(error))
        }
    }

    public func endAudio() async throws {
        if phase == .completed || phase == .failed || phase == .cancelled {
            try await terminal.value()
            return
        }
        guard phase == .streaming, let marker = codec?.endMarker else {
            let error = TranscriptionError(kind: .invalidState, message: "Finish called outside an active session.")
            fail(error)
            throw error
        }
        phase = .ending
        do {
            try await AsyncDeadline.run(seconds: finishTimeout) {
                try await self.write(marker)
                try await self.terminal.value()
                await self.waitForCleanup()
            }
        } catch {
            try await reconcileWriteFailure(Self.classifiedWriteFailure(error))
        }
    }

    /// The reader settles its latch before aborting writes. That result wins
    /// for both audio and end-marker writes, even before event consumption.
    private func reconcileWriteFailure(_ error: Error) async throws {
        if phase == .completed || phase == .failed || phase == .cancelled {
            try await terminal.value()
            return
        }
        // A connection reset also ends the read side, and the reader may be
        // about to deliver the terminal the server already sent. Give it a
        // short bounded chance to settle before the write failure latches;
        // the reader's own verdict (terminal or close) then wins.
        if let reader {
            _ = try? await AsyncDeadline.run(seconds: Self.writeReconcileDrainSeconds) { await reader.value }
        }
        if phase == .completed || phase == .failed || phase == .cancelled {
            try await terminal.value()
            return
        }
        fail(error)
        throw error
    }

    /// How long a failed write waits for the concurrently-finishing reader.
    /// Short: the reset propagates to the read side in milliseconds, and a
    /// genuinely live read side must not stall the writer for longer.
    static let writeReconcileDrainSeconds: Double = 0.5

    /// Mid-session write failures arrive as raw socket NSErrors otherwise;
    /// give them the same deterministic classification the read path applies.
    /// The handshake write keeps its own `.network` wrap.
    private static func classifiedWriteFailure(_ error: Error) -> Error {
        TranscriptionError.classifiedSocketError(error) ?? error
    }

    public func cancel() async {
        if phase != .completed && phase != .failed { fail(CancellationError()) }
        phase = .cancelled
        reader?.cancel()
        connection?.cancel()
        writer?.cancel()
        beginCleanup()
        // A non-cooperative transport can park the reader in its message
        // iterator even after cancel. Bound the join so cancel returns and
        // the hung resource stays quarantined, like every other shutdown path.
        _ = await AsyncDeadline.shutdown(seconds: 2) {
            await self.waitForCancelJoins()
        }
    }

    private func write(_ message: TransportMessage) async throws {
        guard phase == .starting || phase == .streaming || phase == .ending else {
            // A terminal phase means completion or failure already happened.
            // Surface the recorded outcome so a real provider failure is
            // never masked as caller cancellation; a completed session still
            // refuses the late write.
            try await terminal.value()
            throw CancellationError()
        }
        let previous = writer
        let transport = self.transport
        let next = Task {
            try await withTaskCancellationHandler {
                try await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            try Task.checkCancellation()
            try await transport.write(message)
        }
        writer = next
        defer { if writer == next { writer = nil } }
        try await next.value
    }

    private func receive(_ message: TransportMessage) -> Bool {
        guard phase == .starting || phase == .streaming || phase == .ending else { return false }
        if phase == .starting {
            if codec?.isReady(message) == true {
                phase = .streaming
                streamingSince = uptime()
                ready.resolve(.success(()))
            } else if let event = codec?.decode(message), case .error(let error) = event {
                fail(error)
            }
            return phase == .starting || phase == .streaming
        }
        guard let event = codec?.decode(message) else { return true }
        if case .error(let error) = event {
            fail(error)
            return false
        }
        if case .dropped = continuation.yield(event) {
            fail(
                TranscriptionError(
                    kind: .network, message: "The client fell behind the speech service; please try a new take."))
            return false
        }
        if event.isFinal {
            phase = .completed
            terminal.resolve(.success(()))
            continuation.finish()
            beginCleanup()
            return false
        }
        return true
    }

    private func closed() {
        if phase == .ending, codec?.completesOnClose == true {
            phase = .completed
            terminal.resolve(.success(()))
            continuation.finish()
            beginCleanup()
        } else if phase == .starting {
            fail(TranscriptionError.closed("The speech service closed the connection before it was ready. Try again."))
        } else if phase == .streaming || phase == .ending {
            fail(TranscriptionError.closed("The speech service disconnected before finishing. Try again."))
        }
    }

    private func fail(_ error: Error) {
        guard phase != .completed, phase != .failed, phase != .cancelled else { return }
        phase = error is CancellationError ? .cancelled : .failed
        ready.resolve(.failure(error))
        terminal.resolve(.failure(error))
        if let failure = error as? TranscriptionError { continuation.yield(.error(failure)) }
        continuation.finish(throwing: error)
        reader?.cancel()
        connection?.cancel()
        writer?.cancel()
        beginCleanup()
    }

    private func beginCleanup() {
        guard cleanup == nil else { return }
        let opening = connection
        cleanup = Task { [transport] in
            await transport.close()
            // A non-cooperative connect can create a socket after the first
            // close. Retire that operation and close its late resource too.
            _ = await opening?.result
            await transport.close()
        }
    }

    private func waitForCleanup() async { await cleanup?.value }

    private func waitForCancelJoins() async {
        await cleanup?.value
        await reader?.value
        _ = await writer?.result
    }
}
