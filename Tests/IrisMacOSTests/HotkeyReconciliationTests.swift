import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func reconciliationReleasesOnlyADemonstrablyUpHotkey() {
    var physicallyDown = true
    var state = HotkeyEdgeState(keyCode: 0, physicalKeyDown: { _ in physicallyDown })
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.reconcile() == nil)
    #expect(state.isDown)

    physicallyDown = false
    #expect(state.reconcile() == .released)
    #expect(!state.isDown)
    #expect(state.reconcile() == nil)
}

@Test func reconciliationPreservesChordAndRecoverySemantics() {
    var physicallyDown = true
    var chord = HotkeyEdgeState(keyCode: 0, physicalKeyDown: { _ in physicallyDown })
    #expect(chord.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(chord.handle(.init(kind: .keyDown, keyCode: 9)) == .cancelled)
    physicallyDown = false
    #expect(chord.reconcile() == nil)
    #expect(!chord.isDown)

    var recovery = HotkeyEdgeState(keyCode: 0, physicalKeyDown: { _ in false })
    recovery.reset(requireRelease: true)
    #expect(recovery.awaitingRelease)
    #expect(recovery.reconcile() == nil)
    #expect(!recovery.awaitingRelease)
}

@Test @MainActor func monitorRefreshClearsAnIdleRequireReleaseLatch() async throws {
    let backend = TestHotkeyEvents()
    backend.keyPressed = true
    let monitor = GlobalHotkeyMonitor(keyCode: 0, backend: backend)
    #expect(monitor.start())
    let stream = monitor.events()
    let nextEdge = Task { @MainActor in
        var edges = stream.makeAsyncIterator()
        return await edges.next()
    }
    await Task.yield()
    backend.keyPressed = false
    monitor.reconcile()
    backend.globalHandlers.last?(.init(kind: .keyDown, keyCode: 0))
    let edge = try await AsyncDeadline.run(seconds: 1) { await nextEdge.value }
    #expect(edge == .pressed)
    monitor.stop()
}

@MainActor
private func beginBackendRecordedTake(
    in environment: AppEnvironment, fixture: RuntimeFixture, backend: TestHotkeyEvents
) async throws {
    let recording = AsyncStream.makeStream(of: Void.self)
    let original = environment.runtime.onSnapshot
    environment.runtime.onSnapshot = { snapshot in
        original?(snapshot)
        if case .recording(let level) = snapshot.state, level > 0 { recording.continuation.yield(()) }
    }
    defer { environment.runtime.onSnapshot = original }

    backend.keyPressed = true
    backend.globalHandlers.first?(.init(kind: .keyDown, keyCode: 0))
    try await AsyncDeadline.run(seconds: 5) {
        var starts = fixture.audio.started.stream.makeAsyncIterator()
        _ = await starts.next()
        await fixture.audio.emitFrame()
        var recorded = recording.stream.makeAsyncIterator()
        _ = await recorded.next()
    }
}

@Test @MainActor func refreshReleasesAHeldTakeAfterItsKeyUpWasLost() async throws {
    let fixture = RuntimeFixture()
    let backend = TestHotkeyEvents()
    let monitor = GlobalHotkeyMonitor(keyCode: 0, backend: backend)
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    var defaults = AppSettings.defaults
    defaults.hotkey = HotkeyConfiguration(keyCode: 0, mode: .hold)
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports(hotkey: monitor), defaults: defaults)
    await environment.start()
    do {
        try await beginBackendRecordedTake(in: environment, fixture: fixture, backend: backend)

        // No key-up or unrelated keyboard event follows. The existing refresh
        // tick alone observes physical state and closes the open take.
        backend.keyPressed = false
        fixture.systemEvents.emit(.refresh)
        try await AsyncDeadline.run(seconds: 5) {
            var stops = fixture.audio.stopped.stream.makeAsyncIterator()
            _ = await stops.next()
        }
        #expect(await fixture.audio.stops == 1)
        #expect(environment.runtime.isMonitoring)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}
