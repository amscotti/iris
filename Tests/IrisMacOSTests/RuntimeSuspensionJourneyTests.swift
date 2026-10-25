import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private enum JourneyRevokedGrant: String, CaseIterable, Sendable {
    case microphone, accessibility

    var reason: DictationNotice.CancellationReason {
        self == .microphone ? .microphoneDenied : .accessibilityDenied
    }

    var suspension: InputSuspensionReason {
        self == .microphone ? .microphoneDenied : .accessibilityDenied
    }

    var guidance: String {
        switch self {
        case .microphone:
            return "Microphone access was lost. The current dictation was cancelled. Enable it in Settings to resume."
        case .accessibility:
            return
                "Accessibility access was lost. The current dictation was cancelled. Enable it in Settings to resume."
        }
    }

    func set(_ granted: Bool, in grants: RuntimeJourneyGrants) {
        switch self {
        case .microphone: grants.update(microphone: granted)
        case .accessibility: grants.update(accessibility: granted)
        }
    }
}

@Test(arguments: JourneyRevokedGrant.allCases) @MainActor
private func runtimeSuspensionJourneyRevokedGrantCancelsAndRestoresFreshInput(grant: JourneyRevokedGrant) async throws {
    try await withRuntimeSuspensionJourney { journey in
        try await journey.beginRecordedTake()
        grant.set(false, in: journey.grants)
        journey.fixture.systemEvents.emit(.refresh)
        #expect(try await journey.waitForCleanup() == .clean)
        let notice = DictationNotice.cancelled(grant.reason)
        #expect(journey.notices == [notice])
        #expect(notice.severity == .warning)
        #expect(journey.environment.lastDictationError == grant.guidance)
        #expect(journey.environment.pill.lastAnnouncement == grant.guidance)
        #expect(journey.runtime.state == .suspended(grant.suspension))
        #expect(journey.runtime.captureSuspended)
        #expect(!journey.runtime.isMonitoring)
        #expect(await journey.fixture.audio.stops == 1)
        #expect(journey.fixture.inserter.targets.isEmpty)
        #expect(journey.backend.globalHandlers.isEmpty)
        #expect(journey.backend.localHandlers.isEmpty)
        // The UI's injected snapshot stays granted: the mutable runtime ports
        // must independently detect loss, not rely on PermissionsManager.
        #expect(journey.environment.permissions.microphoneGranted)
        #expect(journey.environment.permissions.accessibilityGranted)
        journey.release()
        journey.press()
        try await journey.mainActorCheckpoint()
        #expect(await journey.fixture.audio.starts == 1)
        #expect(journey.services.count == 1)

        grant.set(true, in: journey.grants)
        journey.fixture.systemEvents.emit(.refresh)
        try #require(journey.runtime.state == .ready)
        #expect(journey.backend.globalHandlers.count == 1)
        #expect(journey.backend.localHandlers.count == 1)
        // Two monitor starts plus the refresh probe that reconciles the
        // require-release latch after the revoked grant is restored.
        #expect(journey.backend.physicalReads == 3)
        // This key was held while suspended. Recovery consumes its release,
        // then a genuinely fresh physical press must deliver a new level.
        journey.release()
        try await journey.beginRecordedTake()
        #expect(await journey.fixture.audio.starts == 2)
        #expect(journey.services.count == 2)
        #expect(try await journey.releaseAndWaitForInsertion() == "journey take 2 ")
        try await journey.joinInsertionAndRestartInput()
        #expect(await journey.fixture.audio.stops == 2)
        #expect(journey.fixture.inserter.targets.count == 1)
        #expect(journey.notices == [notice])
    }
}

@Test @MainActor func runtimeSuspensionJourneyPermissionChangeHasTheExactTypedReason() async throws {
    try await withRuntimeSuspensionJourney { journey in
        try await journey.beginRecordedTake()
        try await AsyncDeadline.run(seconds: 5) { await journey.runtime.beginPermissionChange() }
        #expect(journey.notices == [.cancelled(.settingsChange)])
        #expect(journey.environment.lastDictationError == "A settings change cancelled the current dictation.")
        #expect(journey.environment.pill.lastAnnouncement == "A settings change cancelled the current dictation.")
        #expect(journey.runtime.state == .suspended(.permissionOperation))
        #expect(await journey.fixture.audio.stops == 1)
        #expect(journey.fixture.inserter.targets.isEmpty)
        journey.release()
        journey.runtime.endPermissionChange()
        try #require(journey.runtime.state == .ready)
        try await journey.beginRecordedTake()
        #expect(try await journey.releaseAndWaitForInsertion() == "journey take 2 ")
        try await journey.joinInsertionAndRestartInput()
        #expect(journey.notices == [.cancelled(.settingsChange)])
    }
}

@Test @MainActor func runtimeSuspensionJourneyWakeBeforeCleanupKeepsTheFirstSystemCause() async throws {
    let provider = RuntimeJourneyGate()
    try await withRuntimeSuspensionJourney(providerCancellation: provider) { journey in
        try await journey.beginRecordedTake()
        journey.fixture.systemEvents.emit(.sleep)
        _ = try await runtimeJourneyNext(provider.entered.stream, signal: "provider cancellation entry")
        try #require(!provider.isReleased)
        journey.release()
        journey.fixture.systemEvents.emit(.wake)
        #expect(journey.runtime.state == .cleaningUp(.cleaningUpPreviousGeneration))
        #expect(!journey.runtime.isMonitoring)
        let runtime = journey.runtime
        let premature = await AsyncDeadline.shutdown(seconds: 0.05) { _ = await runtime.waitForCleanup() }
        #expect(premature == .timedOut)
        #expect(!journey.runtime.requiresRestart)
        provider.release()
        #expect(try await journey.waitForCleanup() == .clean)
        #expect(journey.notices == [.cancelled(.systemEvent)])
        try #require(journey.runtime.state == .ready)
        try await journey.beginRecordedTake()
        #expect(await journey.fixture.audio.starts == 2)
        #expect(try await journey.releaseAndWaitForInsertion() == "journey take 2 ")
        try await journey.joinInsertionAndRestartInput()
        #expect(journey.notices == [.cancelled(.systemEvent)])
    }
}

@Test @MainActor func runtimeSuspensionJourneyPermissionChangeDuringSleepingCleanupKeepsTheFirstCause() async throws {
    let capture = RuntimeJourneyGate()
    try await withRuntimeSuspensionJourney(captureStop: capture) { journey in
        try await journey.beginRecordedTake()
        journey.fixture.systemEvents.emit(.sleep)
        _ = try await runtimeJourneyNext(capture.entered.stream, signal: "capture stop entry")
        let permissionEntered = AsyncStream.makeStream(of: Void.self)
        let permission = Task { @MainActor in
            permissionEntered.continuation.yield(())
            await journey.runtime.beginPermissionChange()
        }
        defer { permission.cancel() }
        _ = try await runtimeJourneyNext(permissionEntered.stream, signal: "overlapping permission operation")
        try #require(journey.runtime.permissionOperationCount == 1)
        #expect(!capture.isReleased)
        journey.fixture.systemEvents.emit(.sessionInactive)
        journey.fixture.systemEvents.emit(.sleep)
        capture.release()
        try await AsyncDeadline.run(seconds: 5) { await permission.value }
        #expect(try await journey.waitForCleanup() == .clean)
        #expect(journey.notices == [.cancelled(.systemEvent)])
        #expect(await journey.fixture.audio.stops == 1)
        #expect(journey.fixture.inserter.targets.isEmpty)
        journey.release()
        journey.fixture.systemEvents.emit(.wake)
        #expect(!journey.runtime.isMonitoring)
        journey.fixture.systemEvents.emit(.sessionActive)
        #expect(journey.runtime.state == .suspended(.permissionOperation))
        journey.runtime.endPermissionChange()
        try #require(journey.runtime.state == .ready)
        try await journey.beginRecordedTake()
        #expect(try await journey.releaseAndWaitForInsertion() == "journey take 2 ")
        try await journey.joinInsertionAndRestartInput()
        #expect(journey.notices == [.cancelled(.systemEvent)])
    }
}

@Test @MainActor func runtimeSuspensionJourneyCancelCompleteCancelNotifiesOnlyCancelledTakes() async throws {
    try await withRuntimeSuspensionJourney { journey in
        try await journey.beginRecordedTake()
        journey.fixture.systemEvents.emit(.sleep)
        #expect(try await journey.waitForCleanup() == .clean)
        #expect(journey.notices == [.cancelled(.systemEvent)])
        journey.release()
        journey.fixture.systemEvents.emit(.wake)

        try await journey.beginRecordedTake()
        #expect(try await journey.releaseAndWaitForInsertion() == "journey take 2 ")
        #expect(journey.notices == [.cancelled(.systemEvent)])
        try await journey.joinInsertionAndRestartInput()
        // A suspension with no owned take after that joined insertion must
        // not resurrect the completed take's ID as a cancellation notice.
        journey.fixture.systemEvents.emit(.sleep)
        #expect(try await journey.waitForCleanup() == .clean)
        #expect(journey.notices == [.cancelled(.systemEvent)])
        journey.fixture.systemEvents.emit(.wake)

        try await journey.beginRecordedTake()
        try await AsyncDeadline.run(seconds: 5) { await journey.runtime.beginPermissionChange() }
        #expect(journey.notices == [.cancelled(.systemEvent), .cancelled(.settingsChange)])
        #expect(await journey.fixture.audio.starts == 3)
        #expect(await journey.fixture.audio.stops == 3)
        #expect(journey.services.count == 3)
        #expect(journey.fixture.inserter.targets.count == 1)
        journey.release()
        journey.runtime.endPermissionChange()
        #expect(!journey.runtime.requiresRestart)
    }
}

private enum JourneyParkedResource: CaseIterable, Equatable, Sendable { case provider, capture }

@Test(arguments: JourneyParkedResource.allCases) @MainActor
private func runtimeSuspensionJourneyTimeoutKeepsRestartLastAfterResourceRelease(resource: JourneyParkedResource)
    async throws
{
    let gate = RuntimeJourneyGate()
    let provider: RuntimeJourneyGate? = resource == .provider ? gate : nil
    let capture: RuntimeJourneyGate? = resource == .capture ? gate : nil
    try await withRuntimeSuspensionJourney(
        providerCancellation: provider, captureStop: capture, shutdownTimeout: 0.05
    ) { journey in
        try await journey.beginRecordedTake()
        let quarantine = try await journey.nextSnapshot(matching: { $0.requiresRestart }) {
            journey.fixture.systemEvents.emit(.sleep)
            _ = try await runtimeJourneyNext(gate.entered.stream, signal: "non-cooperative resource entry")
            try #require(!gate.isReleased)
            #expect(try await journey.waitForCleanup() == .timedOut)
        }
        #expect(quarantine.lastError == TranscriptionService.restartMessage)
        let restart = DictationNotice.restartRequired(TranscriptionService.restartMessage)
        try #require(journey.notices.last == restart)
        // Cancellation can win the race or be suppressed by quarantine. It
        // may occur once before restart, never after the restart notice.
        #expect(journey.notices == [restart] || journey.notices == [.cancelled(.systemEvent), restart])
        let beforeRelease = journey.notices
        gate.release()
        if let parkedCapture = journey.parkedCapture {
            _ = try await runtimeJourneyNext(parkedCapture.stopReturned.stream, signal: "late capture stop return")
        } else {
            let client = try #require(journey.services.first)
            _ = try await runtimeJourneyNext(client.cancelReturned.stream, signal: "late provider cancel return")
        }
        try await journey.mainActorCheckpoint()
        journey.release()
        journey.fixture.systemEvents.emit(.wake)
        journey.fixture.systemEvents.emit(.refresh)
        journey.press()
        journey.release()
        try await journey.mainActorCheckpoint()
        #expect(journey.notices == beforeRelease)
        #expect(journey.notices.last == restart)
        #expect(journey.runtime.state == .restartRequired(TranscriptionService.restartMessage))
        #expect(journey.environment.lastDictationError == TranscriptionService.restartMessage)
        #expect(journey.runtime.isStarted)
        #expect(!journey.runtime.isMonitoring)
        #expect(await journey.fixture.audio.starts == 1)
        #expect(journey.fixture.inserter.targets.isEmpty)
    }
}

@Test @MainActor func runtimeSuspensionJourneyStopSuppressesCancellationAndJoinsProviderCleanup() async throws {
    let provider = RuntimeJourneyGate()
    try await withRuntimeSuspensionJourney(providerCancellation: provider) { journey in
        try await journey.beginRecordedTake()
        let stopping = Task { await journey.runtime.stop() }
        defer { stopping.cancel() }
        _ = try await runtimeJourneyNext(provider.entered.stream, signal: "ordinary stop provider cleanup")
        _ = try await runtimeJourneyNext(journey.fixture.audio.stopped.stream, signal: "ordinary stop capture drain")
        #expect(!journey.runtime.isStarted)
        #expect(!journey.runtime.isMonitoring)
        #expect(await journey.fixture.audio.stops == 1)
        #expect(journey.notices.isEmpty)
        let premature = await AsyncDeadline.shutdown(seconds: 0.05) { await stopping.value }
        #expect(premature == .timedOut)
        #expect(!provider.isReleased)
        provider.release()
        try await AsyncDeadline.run(seconds: 5) { await stopping.value }
        #expect(journey.runtime.state == .stopped)
        #expect(journey.notices.isEmpty)
        #expect(journey.fixture.inserter.targets.isEmpty)
        #expect(!journey.runtime.requiresRestart)
    }
}

@Test @MainActor func runtimeSuspensionJourneyConcurrentStopStartKeepsTheNewSnapshotObserver() async throws {
    let provider = RuntimeJourneyGate()
    try await withRuntimeSuspensionJourney(providerCancellation: provider) { journey in
        try await journey.beginRecordedTake()
        let stopping = Task { await journey.runtime.stop() }
        defer { stopping.cancel() }
        _ = try await runtimeJourneyNext(provider.entered.stream, signal: "retiring generation provider cleanup")
        try #require(!journey.runtime.isStarted)
        try #require(!provider.isReleased)
        journey.release()
        let initial = try await journey.nextSnapshot(matching: { $0.state == .idle }) {
            await journey.runtime.start()
        }
        #expect(initial.lastError == nil)
        #expect(journey.runtime.isStarted)
        #expect(!journey.runtime.isMonitoring)
        provider.release()
        try await AsyncDeadline.run(seconds: 5) { await stopping.value }
        try #require(journey.runtime.state == .ready)
        // Install a fresh level barrier only after the OLD stop returned. A
        // cancelled replacement observer would leave monitoring true but can
        // never deliver this snapshot from the NEW audio stream generation.
        let recorded = try await journey.beginRecordedTake()
        if case .recording(let level) = recorded.state {
            #expect(level > 0)
        } else {
            Issue.record("Replacement observation never delivered a recorded level")
        }
        #expect(journey.environment.statusLine == "Listening…")
        #expect(await journey.fixture.audio.starts == 2)
        #expect(journey.services.count == 2)
        #expect(try await journey.releaseAndWaitForInsertion() == "journey take 2 ")
        try await journey.joinInsertionAndRestartInput()
        #expect(journey.notices.isEmpty)
        #expect(journey.fixture.inserter.targets.count == 1)
        #expect(!journey.runtime.requiresRestart)
    }
}
