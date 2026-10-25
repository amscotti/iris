import Foundation

/// Owns one take's live event consumer, terminal result and cleanup. UI states
/// never determine success: finish returns the independently retained outcome.
public actor TranscriptionService {
    public static let restartMessage = "Speech session did not shut down. Restart the app before dictating again."
    private static let cancelledDeliveryError = TranscriptionError(
        kind: .network, message: "Audio delivery was cancelled before the speech service finished. Try again.")

    private let client: any TranscriptionClient
    private let completion: TranscriptCompletionPolicy
    private let shutdownTimeout: Double
    private var session = TranscriptionSession()
    private var current: PushToTalkState = .idle
    private var outcome: TranscriptionOutcome?
    private var lastFinalText: String?
    private var generation = 0
    private var startup: Task<Void, Error>?
    private var ending: Task<Void, Error>?
    private var delivery: Task<Void, Error>?
    private var deliverySettlement: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var cleanup: Task<SessionShutdown, Never>?
    private let observations = StateBroadcast<PushToTalkState>()
    public private(set) var requiresRestart = false

    public init(
        client: any TranscriptionClient, completion: TranscriptCompletionPolicy = .finalEvent,
        shutdownTimeout: Double = 2
    ) {
        self.client = client
        self.completion = completion
        self.shutdownTimeout = shutdownTimeout
    }

    public var currentState: PushToTalkState { current }
    public var lastFinal: String? { lastFinalText }
    public var terminalOutcome: TranscriptionOutcome? { outcome }
    /// True when transcript text was recorded this session, including
    /// endpointing turns that never surfaced as partials. The silent-take
    /// heuristic consults this so real words are not discarded as a tap.
    public var hasRecordedTranscript: Bool { session.hasRecordedTranscript }
    var subscriberCount: Int { observations.count }

    /// Lossless session events for the orchestrator and diagnostics. The
    /// orchestrator exposes a separate latest-only snapshot API for UI views.
    public func states() -> AsyncStream<PushToTalkState> { observations.stream(initial: current) }

    public func start(config: ProviderConfiguration) async throws {
        try Task.checkCancellation()
        guard !requiresRestart else {
            throw TranscriptionError(kind: .invalidState, message: Self.restartMessage)
        }
        generation += 1
        let token = generation
        session.begin()
        outcome = nil
        lastFinalText = nil
        cleanup = nil
        ending = nil
        delivery = nil
        deliverySettlement = nil
        let opening = Task { [client] in try await client.start(config: config) }
        startup = opening
        do {
            try await AsyncDeadline.run(seconds: 15) { try await opening.value }
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            emit(.recording(level: 0))
            let events = client.events()
            reader = Task { [weak self] in await self?.consume(events, generation: token) }
        } catch {
            guard generation == token else { throw CancellationError() }
            if error is CancellationError || Task.isCancelled {
                _ = await cancel()
                throw CancellationError()
            }
            fail(error)
            throw error
        }
    }

    public func appendAudio(_ frame: PCMFrame) async throws {
        if case .completed = outcome { return }
        // A recorded failure/cancellation outranks the generic state error.
        if case .failed(let failure) = outcome { throw failure }
        if case .cancelled = outcome { throw CancellationError() }
        guard session.phase == .recording else {
            throw TranscriptionError(kind: .invalidState, message: "Audio appended outside a recording session.")
        }
        let token = generation
        let sending = Task { [client] in try await client.sendAudio(frame) }
        delivery = sending
        do { try await sending.value } catch {
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            // The session may have already recorded a real terminal outcome
            // (auth/rate/close) while this send was in flight; a write
            // aborted by that teardown must not overwrite it with a
            // generic "couldn't be completed" error.
            guard outcome == nil else { throw CancellationError() }
            if Self.isCancellation(error) {
                settleCancelledDelivery(generation: token)
                throw CancellationError()
            }
            // A queued terminal outranks the teardown error, exactly as for
            // a cancelled send: let the reader drain (shortly bounded)
            // before this failure decides how the recording ended.
            settleDelivery(
                fallback: Self.failureFallback(error), generation: token,
                seconds: Self.failedDeliverySettleSeconds)
            _ = await joinDeliverySettlement(generation: token)
            throw error
        }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        guard outcome == nil else { return }
        emit(.recording(level: frame.rms))
    }

    public func failAudioDelivery(_ error: Error) async {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // A queued terminal outranks the teardown error, like failed sends:
        // give the reader the same short settlement before failing.
        if outcome == nil, !Self.isCancellation(error) {
            settleDelivery(
                fallback: Self.failureFallback(error), generation: generation,
                seconds: Self.failedDeliverySettleSeconds)
            _ = await joinDeliverySettlement(generation: generation)
        }
        fail(error)
    }

    @discardableResult
    public func finish() async -> TranscriptionOutcome {
        let token = generation
        guard await joinDeliverySettlement(generation: token), generation == token else { return .cancelled }
        if outcome == nil, session.phase == .recording {
            if Task.isCancelled {
                _ = await cancel()
                return .cancelled
            }
            session.beginFinalizing()
            let end = Task { [client] in try await client.endAudio() }
            ending = end
            let consumer = reader
            do {
                try await AsyncDeadline.run(seconds: 20) {
                    try await end.value
                    await consumer?.value
                }
            } catch {
                await handleFinishFailure(error, generation: token)
            }
            if generation == token, outcome == nil { closed(error: nil) }
        }
        guard generation == token else { return .cancelled }
        let shutdown = await finishCleanup()
        guard generation == token else { return .cancelled }
        if shutdown == .timedOut {
            requiresRestart = true
            // Cleanup quarantine must not erase speech that already reached a
            // terminal completion. The orchestrator inserts this result before
            // propagating the restart latch; failed/cancelled takes still fail.
            if case .completed(let text) = outcome { return .completed(text) }
            lastFinalText = nil
            return .failed(TranscriptionError(kind: .timeout, message: Self.restartMessage))
        }
        return outcome ?? .cancelled
    }

    @discardableResult
    public func cancel() async -> SessionShutdown {
        generation += 1
        session = TranscriptionSession()
        // A terminal recorded just before cancel (completion/failure) is the
        // take's result; cancel only fills in .cancelled when nothing settled
        // (mirrors fail()'s outcome == nil guard).
        if outcome == nil {
            outcome = .cancelled
            lastFinalText = nil
        }
        emit(.idle)
        let shutdown = await finishCleanup()
        if shutdown == .timedOut { requiresRestart = true }
        return shutdown
    }

    private func beginCleanup() {
        guard cleanup == nil else { return }
        startup?.cancel()
        ending?.cancel()
        delivery?.cancel()
        deliverySettlement?.cancel()
        reader?.cancel()
        let opening = startup
        let end = ending
        let sending = delivery
        let settlement = deliverySettlement
        let consumer = reader
        cleanup = Task { [client, shutdownTimeout] in
            await AsyncDeadline.shutdown(seconds: shutdownTimeout) {
                await client.cancel()
                _ = await opening?.result
                _ = await end?.result
                _ = await sending?.result
                await settlement?.value
                await consumer?.value
            }
        }
    }

    private func finishCleanup() async -> SessionShutdown {
        beginCleanup()
        return await cleanup?.value ?? .clean
    }

    private func consume(_ events: AsyncThrowingStream<TranscriptionEvent, Error>, generation token: Int) async {
        do {
            for try await event in events {
                guard generation == token, !Task.isCancelled, outcome == nil else { return }
                handle(event)
                if outcome != nil { return }
            }
            if generation == token, !Task.isCancelled, outcome == nil { closed(error: nil) }
        } catch {
            if generation == token, !Task.isCancelled, outcome == nil { closed(error: error) }
        }
    }

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let text):
            session.accumulate(partial: text)
            emit(.partial(text))
        case .final(let text):
            if let done = session.complete(final: text) {
                outcome = .completed(done)
                // Emit the terminal state even when blank: an empty
                // completion is the "no speech was recognized" signal the
                // UI explains to the user. Only real text is retained.
                if !done.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastFinalText = done
                }
                emit(.final(done))
                emit(.idle)
            }
        case .speechStarted: break
        case .speechComplete(let id, let transcript):
            guard completion == .turnComplete else { return }
            session.recordTurn(id: id, text: transcript.isEmpty ? session.partialText : transcript)
        case .error(let error): fail(error)
        }
    }

    private func closed(error: Error?) {
        if let error {
            fail(error)
            return
        }
        if completion == .turnComplete {
            let text = session.finishTurns() ?? ""
            outcome = .completed(text)
            if !text.isEmpty { lastFinalText = text }
            emit(.final(text))
            emit(.idle)
        } else {
            fail(TranscriptionError.closed("The speech service disconnected before finishing. Try again."))
        }
    }

    private func fail(_ error: Error) {
        guard outcome == nil else { return }
        let failure =
            (error as? TranscriptionError)
            ?? (Self.isCancellation(error)
                ? Self.cancelledDeliveryError
                : TranscriptionError(kind: .unknown, message: error.localizedDescription))
        outcome = .failed(failure)
        lastFinalText = nil
        session.fail(failure)
        emit(.error(failure.message))
        emit(.idle)
        beginCleanup()
    }

    private func emit(_ state: PushToTalkState) {
        current = state
        observations.send(state)
    }
}

extension TranscriptionService {
    fileprivate func handleFinishFailure(_ error: Error, generation token: Int) async {
        guard generation == token, outcome == nil else { return }
        if Task.isCancelled {
            _ = await cancel()
        } else if Self.isCancellation(error) {
            // A transport teardown is not caller cancellation. Let the queued
            // terminal settle before deciding how this recording ended.
            settleCancelledDelivery(generation: token)
            _ = await joinDeliverySettlement(generation: token)
        } else {
            // The same rule for real finish failures: a queued terminal
            // that already arrived wins over the teardown error.
            settleDelivery(
                fallback: Self.failureFallback(error), generation: token,
                seconds: Self.failedDeliverySettleSeconds)
            _ = await joinDeliverySettlement(generation: token)
            if outcome == nil { fail(error) }
        }
    }

    fileprivate static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// A send failure that survives the settlement window fails with the
    /// error it arrived with, classified shape preserved.
    fileprivate static func failureFallback(_ error: Error) -> TranscriptionError {
        (error as? TranscriptionError)
            ?? TranscriptionError(kind: .unknown, message: error.localizedDescription)
    }

    /// How long a failed (non-cancellation) send waits for an already
    /// queued terminal to reach the reader before it decides the outcome.
    /// Short: the message only needs one reader hop, and a live-but-empty
    /// read side must not stall the pump for the full shutdown budget.
    static let failedDeliverySettleSeconds: Double = 0.3

    fileprivate func settleCancelledDelivery(generation token: Int) {
        settleDelivery(fallback: Self.cancelledDeliveryError, generation: token, seconds: shutdownTimeout)
    }

    /// Let a queued terminal reach the reader before the caller's teardown
    /// error decides the outcome, bounded by `seconds`.
    fileprivate func settleDelivery(
        fallback: TranscriptionError, generation token: Int, seconds: Double
    ) {
        guard deliverySettlement == nil else { return }
        session.beginFinalizing()
        let consumer = reader
        deliverySettlement = Task { [seconds] in
            // Return the send reply now, allowing a queued terminal to reach
            // the reader. A client that never ends its stream gets a bounded,
            // explicit failure instead of silently remaining in recording.
            _ = try? await AsyncDeadline.run(seconds: seconds) { await consumer?.value }
            guard generation == token, !Task.isCancelled, outcome == nil else { return }
            // Start cleanup and return so its bounded join can include us.
            fail(fallback)
        }
    }

    fileprivate func joinDeliverySettlement(generation token: Int) async -> Bool {
        guard let settlement = deliverySettlement, outcome == nil else { return generation == token }
        await withTaskCancellationHandler {
            await settlement.value
        } onCancel: {
            settlement.cancel()
        }
        guard generation == token else { return false }
        if Task.isCancelled, outcome == nil {
            _ = await cancel()
            return false
        }
        return true
    }
}
