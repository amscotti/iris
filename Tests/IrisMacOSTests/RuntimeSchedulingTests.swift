import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

private struct NextEnded: Error {
    let signal: String
}

private func nextFrom<Value: Sendable>(_ stream: AsyncStream<Value>, signal: String) async throws
    -> Value
{
    try await AsyncDeadline.run(seconds: 5) {
        var input = stream.makeAsyncIterator()
        guard let value = await input.next() else { throw NextEnded(signal: signal) }
        return value
    }
}

/// Inserter that parks mid-insert, then completes: a healthy insert that
/// legitimately outlives the runtime's generic shutdown deadline while
/// staying inside its own pacing budget.
private final class ParkingInserter: ConfigurableTextInserting, @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var texts: [String] = []
    let entered = AsyncStream.makeStream(of: Void.self)

    func update(method: AppSettings.InsertMethod) {}
    func onNotice(_ handler: ((InsertionNotice) -> Void)?) {}
    func insert(_ text: String) { insert(text, target: nil) }

    func insert(_ text: String, target: InsertionTargetSnapshot?) {
        condition.lock()
        entered.continuation.yield(())
        while !released { condition.wait() }
        texts.append(text)
        condition.unlock()
    }

    func releaseInsertions() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    var insertedTexts: [String] {
        condition.lock()
        defer { condition.unlock() }
        return texts
    }
}

@Test @MainActor func suspendDuringASlowButHealthyInsertionDoesNotLatchARestart() async throws {
    let fixture = RuntimeFixture()
    let inserter = ParkingInserter()
    // A tiny generic shutdown deadline so the runtime's outer cleanup
    // deadline fires long before the insertion's own budget expires.
    let supplied = fixture.ports(timeout: 0.05)
    let ports = DictationRuntimePorts(
        audio: supplied.audio, inserter: inserter, hotkey: supplied.hotkey,
        focus: supplied.focus, authorization: supplied.authorization,
        systemEvents: supplied.systemEvents, makeService: supplied.makeService,
        rewriteFactory: supplied.rewriteFactory, shutdownTimeout: 0.05)
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: ports)
    await environment.start()
    try await fixture.beginRecordedTake(in: environment)

    // Release the press; the transcript finalizes and the insert parks.
    fixture.keys.emit(.released)
    _ = try await nextFrom(inserter.entered.stream, signal: "insertion entry")

    // Input suspends while the insertion is still healthy and inside its
    // own budget: the runtime must join it, not latch a restart.
    fixture.systemEvents.emit(.sleep)
    #expect(!environment.runtime.isMonitoring)
    // Hold past the generic shutdown deadline (0.05 s), where the old
    // cleanup deadline used to latch a spurious restart.
    try await Task.sleep(for: .seconds(0.3))

    inserter.releaseInsertions()
    let runtime = environment.runtime
    let cleanup = try await AsyncDeadline.run(seconds: 10) { await runtime.waitForCleanup() }
    #expect(cleanup == .clean)
    #expect(!runtime.requiresRestart)
    #expect(inserter.insertedTexts == ["hello world "])
    await environment.stop()
}

@Test @MainActor func gateHoldReleaseThatWinsTheRaceIsConsumedByItsLateBegin() async throws {
    let fixture = RuntimeFixture()
    let runtime = DictationRuntime(
        settings: .defaults, registry: AppProviderAssembly.defaultRegistry(), ports: fixture.ports())
    await runtime.start()
    #expect(runtime.state == .ready)

    // A release can land in the same-actor scheduling gap after the gate
    // hold flag is set but before its paired begin's prologue has run.
    // It must be queued, not clamped: the late begin then consumes it
    // instead of leaving an unbalanced count suspending input forever.
    runtime.endPermissionChange()
    #expect(runtime.permissionOperationCount == 0)
    await runtime.beginPermissionChange()
    #expect(runtime.permissionOperationCount == 0)
    #expect(runtime.state == .ready)

    // Normal pairs keep the counting semantics.
    await runtime.beginPermissionChange()
    #expect(runtime.permissionOperationCount == 1)
    runtime.endPermissionChange()
    #expect(runtime.permissionOperationCount == 0)
    #expect(runtime.state == .ready)
    await runtime.stop()
}
