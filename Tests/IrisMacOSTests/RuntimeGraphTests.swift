import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

@MainActor
private final class RuntimePause {
    let entered = AsyncStream.makeStream(of: Void.self)
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var released = false
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            entered.continuation.yield(())
            if released {
                continuation?.resume()
                continuation = nil
            }
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func waitUntilEntered() async {
        var input = entered.stream.makeAsyncIterator()
        _ = await input.next()
    }
    func watchdog() -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            release()
        }
    }
}

@MainActor
private func runtimeEnvironment(_ fixture: RuntimeFixture, pause: RuntimePause, timeout: Double = 2) async throws
    -> AppEnvironment
{
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let prompt = PromptDefinition(template: "Rewrite")
    try AppSettings(prompts: [prompt], selectedPromptID: prompt.id).save(to: store.persistence)
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports(
            rewrite: { _ in
                { _, _ in
                    await pause.wait()
                    return "rewritten words"
                }
            }, timeout: timeout))
    await environment.start()
    return environment
}

@Test @MainActor func applicationGraphCapturesTheTargetBeforeARewriteFocusChange() async throws {
    let fixture = RuntimeFixture()
    let pause = RuntimePause()
    let watchdog = pause.watchdog()
    defer {
        watchdog.cancel()
        pause.release()
    }
    let environment = try await runtimeEnvironment(fixture, pause: pause)
    do {
        try await fixture.beginRecordedTake(in: environment)
        fixture.keys.emit(.released)
        try await AsyncDeadline.run(seconds: 5) { await pause.waitUntilEntered() }
        fixture.focus.update(pid: 2)
        pause.release()
        let inserted = try await AsyncDeadline.run(seconds: 5) {
            var input = fixture.inserter.inserted.stream.makeAsyncIterator()
            return await input.next()
        }
        #expect(inserted == "rewritten words ")
        #expect(fixture.inserter.targets.first??.pid == 1)
        #expect(fixture.focus.currentTarget()?.pid == 2)
        #expect(await fixture.audio.starts == 1)
        #expect(await fixture.audio.stops == 1)
    } catch {
        pause.release()
        await environment.stop()
        throw error
    }
    await environment.stop()
}

@Test @MainActor func runtimeTimeoutIsVisibleAndCannotResumeAfterPermissionsChange() async throws {
    let fixture = RuntimeFixture()
    let pause = RuntimePause()
    let watchdog = pause.watchdog()
    defer {
        watchdog.cancel()
        pause.release()
    }
    let environment = try await runtimeEnvironment(fixture, pause: pause, timeout: 0.05)
    do {
        try await fixture.beginRecordedTake(in: environment)
        fixture.keys.emit(.released)
        try await AsyncDeadline.run(seconds: 5) { await pause.waitUntilEntered() }
        await environment.beginPermissionChange()
        #expect(!pause.released)
        #expect(environment.requiresRelaunch)
        #expect(environment.statusLine == "Restart Iris to resume dictation")
        #expect(!environment.runtime.isMonitoring)
        if case .restartRequired = environment.inputState {} else { Issue.record("Missing explicit restart state") }
        environment.endPermissionChange()
        #expect(!environment.runtime.isMonitoring)
        pause.release()
    } catch {
        pause.release()
        await environment.stop()
        throw error
    }
    await environment.stop()
    #expect(fixture.inserter.targets.isEmpty)
    #expect(environment.requiresRelaunch)
}

private final class RuntimePausedStartClient: TranscriptionClient, Sendable {
    let pause: RuntimePause
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    init(pause: RuntimePause) { self.pause = pause }
    func start(config: ProviderConfiguration) async throws {
        await pause.wait()
        try Task.checkCancellation()
    }
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        channel.continuation.yield(.final("unexpected"))
        channel.continuation.finish()
    }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test @MainActor func runtimeReleaseStopsCaptureWhileTheProviderIsStillConnecting() async throws {
    let fixture = RuntimeFixture()
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let pause = RuntimePause()
    let watchdog = Task {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        pause.release()
    }
    defer {
        watchdog.cancel()
        pause.release()
    }
    let client = RuntimePausedStartClient(pause: pause)
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports(service: { _ in TranscriptionService(client: client) }))
    await environment.start()
    do {
        fixture.keys.emit(.pressed)
        try await AsyncDeadline.run(seconds: 5) { await pause.waitUntilEntered() }
        fixture.keys.emit(.released)
        try await AsyncDeadline.run(seconds: 1) {
            var stops = fixture.audio.stopped.stream.makeAsyncIterator()
            _ = await stops.next()
        }
        #expect(!pause.released)
        #expect(await fixture.audio.stops == 1)
        pause.release()
    } catch {
        pause.release()
        await environment.stop()
        throw error
    }
    await environment.stop()
    #expect(fixture.inserter.targets.isEmpty)
    #expect(!environment.requiresRelaunch)
}

@Test @MainActor func settingsRecoveryRequiresExplicitActionAndRetainsBothErrors() throws {
    let fixture = TestEnvironment()
    let raw = Data(#"{"schemaVersion":999,"prompts":[{"template":"keep me"}]}"#.utf8)
    try fixture.persistence.save(raw, forKey: AppSettings.storageKey)
    let environment = fixture.make()
    var edited = environment.settings
    edited.trailingSpace = false
    environment.saveSettings(edited)
    #expect(environment.settingsLoadIssue != nil)
    #expect(environment.settingsSaveError != nil)
    #expect(try fixture.persistence.load(key: AppSettings.storageKey) == raw)
    environment.recoverSettings()
    #expect(environment.settingsLoadIssue == nil)
    #expect(environment.settingsSaveError == nil)
    try expectRecoveryBackupPlaceholder(fixture.persistence, original: raw)
}
