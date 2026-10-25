import Foundation

/// The hotkey event loop and service-event forwarding: maps press edges
/// and provider results onto the take lifecycle.
extension DictationOrchestrator {
    public func run(hotkey: any HotkeyMonitoring) async {
        var input = HotkeyIntent()
        // Startup, finalization, and cleanup are take-owned tasks. The input
        // loop keeps consuming edges while they run; no stale press is replayed.
        for await event in hotkey.events() {
            let finished = handleEvent(event, input: &input)
            if finished { break }
        }
        if Task.isCancelled {
            _ = await stop()
        } else {
            let id = currentTake?.id
            await pressEnded()
            if let active = currentTake, active.id == id, active.phase == .finalizing,
                let pending = active.finalization ?? active.forward
            {
                // A live error can be draining capture on its forwarder before
                // it publishes the shutdown barrier. EOF must join that too.
                await joinOwnedTask(pending, id: active.id)
            }
        }
        _ = await waitForCleanup()
    }

    /// One decoded edge. Returns true when the loop must end.
    private func handleEvent(
        _ event: HotkeyEvent, input: inout HotkeyIntent
    ) -> Bool {
        if Task.isCancelled { return true }
        let mode = activeHotkeyMode
        let active = currentTake.map {
            HotkeyIntent.ActiveTake(id: $0.id, phase: $0.phase, isSilentQuickTake: isSilentQuickTake(id: $0.id))
        }
        switch input.reduce(event, mode: mode, active: active) {
        case .none: break
        case .begin:
            if beginPress() != nil, let accepted = currentTake {
                // Configuration can change between preflight and reservation.
                // Physical intent follows the take's immutable snapshot.
                input.acceptedTake(id: accepted.id, mode: accepted.settings.hotkey.mode)
            } else {
                input.refusedTake()
                reportBusyPress()
            }
        case .busy: reportBusyPress()
        case .end(let id): if currentTake?.id == id { _ = beginFinalization() }
        case .cancel(let id): cancelTake(id: id)
        }
        return false
    }

    /// The microphone stopped while this take was live. A local capture loss
    /// is never a WebSocket write-teardown race: fail the take immediately and
    /// request bounded shutdown so a fast server `.final` on truncated audio
    /// cannot outrank the hardware failure or insert a partial transcript.
    public func failCapture(_ message: String, expectedTakeID: Int? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let active = take, expectedTakeID == nil || active.id == expectedTakeID,
            isCurrent(active.id), active.insertion == nil
        else {
            return
        }
        take?.lifecycle.fail()
        reportFailure(trimmed, id: active.id)
        _ = requestStop(preservingError: true)
    }

    /// User-facing text when a press lands while a take is active. It clears
    /// on the next successful press start (`pressBegan` resets `lastError`).
    static let busyMessage = "Finishing previous dictation — try again in a moment."

    /// A refused press reports once per take or cleanup, without consuming
    /// the take's separate real-error latch.
    func reportBusyPress() {
        guard let active = currentTake else {
            reportShutdownBusyPress()
            return
        }
        guard !active.busyNoticeReported else { return }
        take?.busyNoticeReported = true
        // Refusal guidance must not replace a real provider/rewrite failure.
        guard snapshot.lastError == nil || snapshot.lastError == Self.busyMessage else { return }
        // A terminal already published for this take is the result: a busy
        // notice must not replace it. That includes the pre-rewrite final
        // during `.enhancing` — the rewrite republishes a terminal (or a
        // real failure) when it finishes, so the notice has nothing to add.
        // A final from an earlier take (revision unchanged since this press
        // started) still gets the notice.
        if snapshot.terminalRevision != active.terminalRevisionAtStart, case .final = snapshot.lastTerminal {
            return
        }
        note(.error(Self.busyMessage))
    }

    /// Publish busy guidance without minting a terminal or replacing the
    /// retained result. Snapshot consumers observe the revision change on a
    /// non-terminal channel.
    func publishBusyPressNotice() {
        busyPressRevision += 1
        snapshotObservers.send(snapshot)
    }

    /// The cleanup-window counterpart: a press refused while shutdown is
    /// joining reports once, without replacing a real error.
    func reportShutdownBusyPress() {
        guard shutdownTask != nil, !requiresRestart, !shutdownBusyNoticeReported else { return }
        shutdownBusyNoticeReported = true
        guard lastError == nil || lastError == Self.busyMessage else { return }
        // A retained final with no error means the last take succeeded:
        // cleanup guidance for a refused press must not replace it (the
        // snapshot-only counterpart of reportBusyPress's terminal guard).
        if case .final = lastTerminal {
            publishBusyPressNotice()
            return
        }
        note(.error(Self.busyMessage))
    }

    /// A take that ends within `silentTakeSeconds` of starting to record,
    /// with no transcript text ever arriving, looks like an accidental tap.
    /// The threshold covers press latency plus a brief hold; anything the
    /// person actually dictated into is older or has text by the time it ends.
    func isSilentQuickTake(id: Int) -> Bool {
        guard let active = currentTake, active.id == id,
            let began = active.recordingBeganUptime,
            !active.hadTranscript,
            ProcessInfo.processInfo.systemUptime - began < silentTakeSeconds
        else { return false }
        return true
    }

    /// The silent-take rule applied to failures: only server closes qualify.
    /// A close without any completion event right after recording starts is
    /// the signature of an accidental tap; auth, rate-limit, timeout, and
    /// other failures always surface, however quickly they arrive. Words
    /// recorded on endpointing turn boundaries are transcript too — a close
    /// after them is not a tap.
    func isSilentServerClose(id: Int) async -> Bool {
        guard isSilentQuickTake(id: id),
            !(await currentTake?.service?.hasRecordedTranscript ?? false)
        else { return false }
        if case .failed(let failure) = await currentTake?.service?.terminalOutcome {
            return failure.kind == .serverClosed
        }
        return false
    }

    func forward(_ pending: AsyncStream<PushToTalkState>, id: Int) async {
        var sawActive = false
        for await state in pending {
            guard isCurrent(id) else { return }
            if state != .idle { sawActive = true }
            await forwardState(state, id: id)
            if state == .idle, sawActive { return }
        }
    }

    private func forwardState(_ state: PushToTalkState, id: Int) async {
        switch state {
        case .error(let message):
            await handleServiceError(message, id: id)
        case .final(let text):
            await handleServiceFinal(text, id: id)
        case .partial(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                take?.hadTranscript = true
            }
            note(state)
        default: note(state)
        }
    }

    private func handleServiceError(_ message: String, id: Int) async {
        // Decide on the accidental-tap rule before teardown: a slow
        // pressEnder must not push a genuinely quick tap past the window.
        let silentClose = await isSilentServerClose(id: id)
        guard isCurrent(id) else { return }
        take?.lifecycle.fail()
        _ = await stopCapture(id: id)
        guard isCurrent(id) else { return }
        if !silentClose { reportFailure(message, id: id) }
        // This is the take's forwarder: request cleanup and return so its
        // bounded join can include this task without a self-join deadlock.
        _ = requestStop(preservingError: !silentClose)
    }

    private func handleServiceFinal(_ text: String, id: Int) async {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !blank { take?.hadTranscript = true }
        // Decide before teardown so a slow stop cannot change the verdict.
        // Real words riding only on an endpointing turn boundary count as
        // transcript: they never surface as partials, but the session
        // recorded them.
        var recordedTranscript = false
        if let service = take?.service { recordedTranscript = await service.hasRecordedTranscript }
        let silentTap = blank && isSilentQuickTake(id: id) && !recordedTranscript
        _ = await stopCapture(id: id)
        guard isCurrent(id) else { return }
        if silentTap {
            // Accidental tap: a blank result from a take that never
            // captured speech stays silent instead of reporting
            // "no speech" for a press the user didn't mean. Cleanup still
            // retains the provider and all take tasks behind its barrier.
            _ = requestStop()
            return
        }
        note(.final(text))
    }
}
