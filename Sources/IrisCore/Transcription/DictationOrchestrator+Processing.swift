import Foundation

/// Per-take finalization, rewrite processing, and cancellation propagation.
extension DictationOrchestrator {
    func reserveShutdownGeneration() -> Int {
        shutdownGeneration += 1
        return shutdownGeneration
    }

    func clearShutdownTask(generation expected: Int) {
        guard shutdownGeneration == expected else { return }
        shutdownGeneration += 1
        shutdownTask = nil
    }

    func stillStarting(id: Int) -> Bool { isCurrent(id) && take?.phase == .starting }

    func isCurrent(_ id: Int) -> Bool { take?.id == id && !Task.isCancelled && !requiresRestart }

    /// Remaining budget for the current take's cleanup, including a healthy
    /// insertion tail. Runtime suspension uses this instead of a fixed cap.
    public var currentCleanupJoinSeconds: Double {
        guard let active = take else { return shutdownTimeout }
        return Self.cleanupJoinSeconds(for: active, fallback: shutdownTimeout)
    }

    /// Publish the cleanup barrier before yielding. Callers running on an
    /// owned task request shutdown and return, rather than joining themselves.
    @discardableResult
    func requestStop(
        preservingError: Bool = false, notifyingCancellation: Bool = false,
        cancellationReason: DictationNotice.CancellationReason? = nil
    ) -> Task<SessionShutdown, Never>? {
        if let shutdownTask { return shutdownTask }
        // Already idle: no generation bump, no cleanup task, no spurious
        // idle broadcast on repeated stops.
        guard let active = take else { return nil }
        let captureStop = captureStopTask(for: active)
        let insertionInFlight = active.insertion != nil
        let cancelled = (notifyingCancellation && !insertionInFlight) ? onCancelledTake : nil
        generation += 1
        take = nil
        active.cancelOwnedTasks()
        // A stale notice from the cancelled take must not be re-adopted by
        // the idle snapshot that follows (e.g. the busy-press message
        // overwriting a cancellation notice). An insertion already in flight
        // runs to completion and keeps its published terminal.
        if !preservingError, !insertionInFlight {
            lastError = nil
            lastTerminal = nil
        }
        note(.idle)
        shutdownBusyNoticeReported = false
        let joinBudget = Self.cleanupJoinSeconds(for: active, fallback: shutdownTimeout)
        let shutdownToken = reserveShutdownGeneration()
        let pending = Task { [joinBudget] in
            let result: SessionShutdown
            do {
                result = try await AsyncDeadline.run(seconds: joinBudget, ignoringCancellation: true) {
                    // Publish cancellation at the actual ownership transfer,
                    // not from a racy query after the take has been cleared.
                    async let notification: Void? = cancelled?(active.id, cancellationReason)
                    async let provider = active.service?.cancel()
                    await captureStop.value
                    _ = await active.gate?.value
                    _ = await active.captureStart?.value
                    _ = await active.startup?.value
                    await active.audio?.value
                    await active.forward?.value
                    _ = await active.processing?.value
                    _ = await active.insertion?.value
                    await active.softDeadline?.value
                    await active.finalization?.value
                    _ = await notification
                    return await provider ?? .clean
                }
            } catch { result = .timedOut }
            if result == .timedOut {
                // A superseded cleanup may finish after a newer take starts;
                // only this cleanup's own take (or no take) may latch restart.
                if shutdownGeneration == shutdownToken, take == nil || take?.id == active.id {
                    requireRestart()
                }
            } else {
                clearShutdownTask(generation: shutdownToken)
            }
            return result
        }
        shutdownTask = pending
        return pending
    }

    /// Uses the continuous-clock task timer rather than wall time. Firing only
    /// requests the same finalization path as a release; it never fails a send.
    func scheduleSoftTakeDeadline(id: Int) {
        let seconds = softTakeTimeout
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.softTakeDeadlineReached(id: id)
        }
        take?.softDeadline = deadline
    }

    private func softTakeDeadlineReached(id: Int) {
        guard isCurrent(id), take?.phase == .recording else { return }
        _ = beginFinalization()
    }

    /// Cancels the current take through the bounded shutdown path without
    /// finalizing or inserting it. A delayed caller may require the same take
    /// ID; insertion has its own deadline/cancellation boundary and is not
    /// interrupted by this ordinary take-cancellation request.
    @discardableResult
    public func cancelActiveTake(
        expectedID: Int? = nil, cancellationReason: DictationNotice.CancellationReason? = nil
    ) async -> Bool {
        guard let active = take, active.insertion == nil,
            expectedID == nil || active.id == expectedID
        else { return false }
        _ = await requestStop(notifyingCancellation: true, cancellationReason: cancellationReason)?.value
        return true
    }

    /// Begin-gate and capture-start prefix of `startTake`: refusal ends the
    /// take with its message; capture failure stops preserving the error.
    func runStartupGates(id: Int) async -> Bool {
        let gating = Task { [gate] in await gate?() }
        take?.gate = gating
        let refusal = await gating.value
        guard stillStarting(id: id) else { return false }
        if let refusal {
            take = nil
            note(.error(refusal))
            note(.idle)
            return false
        }
        let captureStart = Task { [pressStarter, pressStarterWithID] in
            if let pressStarterWithID { return await pressStarterWithID(id) }
            return await pressStarter?()
        }
        take?.captureStart = captureStart
        let failure = await captureStart.value
        guard stillStarting(id: id) else { return false }
        if let failure {
            reportFailure(failure, id: id)
            _ = requestStop(preservingError: true)
            return false
        }
        return true
    }

    /// Resolves the insertion target off-actor (the live provider runs AX
    /// queries) so a wedged frontmost app cannot stall press handling.
    func resolveTarget(id: Int) async -> Bool {
        guard let insertionTargetProvider else { return true }
        let resolving = Task.detached(priority: .userInitiated) { insertionTargetProvider() }
        take?.targetResolution = resolving
        let resolved = await resolving.value
        guard stillStarting(id: id) else { return false }
        take?.target = resolved
        return true
    }

    /// Finalization runs independently of the input loop. Its phase and task
    /// are registered synchronously, so subsequent presses are rejected now.
    func beginFinalization() -> Task<Void, Never>? {
        guard let active = take, active.phase != .finalizing, !Task.isCancelled else { return nil }
        // Release during startup never finalizes: cancel so the in-flight
        // pressBegan cannot resurrect the released take into .recording.
        let transition = take?.lifecycle.release()
        if transition == .cancelStartup || active.service == nil {
            _ = requestStop()
            return nil
        }
        guard transition == .finishRecording else { return nil }
        // A manual release retires the timer; when the timer itself fires,
        // self-cancellation is harmless and the new unstructured task remains
        // independent. Either way only this generation can finalize.
        take?.softDeadline?.cancel()
        let finalization = Task { await self.finalizeTake(active) }
        take?.finalization = finalization
        return finalization
    }

    /// Unstructured take tasks do not inherit a waiting caller's cancellation.
    /// Propagate it explicitly, scoped to this id so a late caller cannot stop
    /// a newer take after its own task has already completed.
    func joinOwnedTask<Value: Sendable>(_ task: Task<Value, Never>, id: Int) async -> Value {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { await self.cancelTake(id: id) }
        }
    }

    func cancelTake(id: Int) {
        guard currentTake?.id == id else { return }
        _ = requestStop()
    }

    func enhance(_ text: String, take active: DictationTake) async -> String {
        guard isCurrent(active.id), let runner = active.rewrite, active.settings.selectedPrompt != nil,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return text }
        note(.enhancing)
        let processing = Task { await RewritePrompt.run(text: text, settings: active.settings, runner: runner) }
        take?.processing = processing
        let result = await processing.value
        guard isCurrent(active.id) else { return text }
        if result.failed {
            note(.error("Rewrite failed. Inserted the original text."))
            note(.idle)
        } else {
            note(.final(result.text))
            note(.idle)
        }
        return result.text
    }

    func reportFailure(_ message: String, id: Int) {
        guard isCurrent(id), take?.errorReported == false else { return }
        take?.errorReported = true
        note(.error(message))
    }

    /// The audio pump overran its deadline: surface the failure and end the
    /// take with a bounded shutdown. A terminal the service recorded while
    /// the pump was parked in a wedged write is still the take's result —
    /// insert a completed one, keep a real failure's message, and fall back
    /// to the deadline error only when nothing settled. The service close
    /// runs behind the shutdown barrier so a new press cannot start
    /// mid-close, and a cleanup that cannot join latches the same visible
    /// restart the normal stop path would.
    func pumpDeadlineExceeded(_ error: Error, active: DictationTake, id: Int) async {
        guard isCurrent(id) else { return }
        var outcome = await active.service?.terminalOutcome
        if outcome == nil {
            await active.service?.failAudioDelivery(error)
            // A terminal may have landed in the same window: the service's
            // fail no-ops on a settled outcome, and that result outranks
            // the deadline error.
            outcome = await active.service?.terminalOutcome
        }
        switch outcome {
        case .completed(let text):
            await completeTake(.completed(text), active: active, id: id)
            // A concurrent stop may already own the barrier. Its cleanup
            // includes this service's close and its timeout verdict; never
            // replace it with a second, weaker closing task.
            guard shutdownTask == nil, let service = active.service else { return }
            let shutdownToken = reserveShutdownGeneration()
            let closing = Task {
                let shutdown = await service.cancel()
                if shutdown == .timedOut {
                    // Only this take's own close may latch: if a new take
                    // somehow began, a late cleanup must not cancel it.
                    if take == nil || take?.id == id { requireRestart() }
                } else {
                    clearShutdownTask(generation: shutdownToken)
                }
                return shutdown
            }
            shutdownTask = closing
        case .failed(let failure):
            reportFailure(failure.message, id: id)
            _ = requestStop(preservingError: true)
        default:
            reportFailure((error as? TranscriptionError)?.message ?? error.localizedDescription, id: id)
            _ = requestStop(preservingError: true)
        }
    }
}
