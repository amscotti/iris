import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func idleSystemSuspensionsDoNotReportACancelledTake() async throws {
    let fixture = RuntimeFixture()
    let runtime = DictationRuntime(
        settings: .defaults, registry: AppProviderAssembly.defaultRegistry(), ports: fixture.ports())
    var notices: [DictationNotice] = []
    runtime.onNotice = { notices.append($0) }
    await runtime.start()
    fixture.systemEvents.emit(.sleep)
    _ = await runtime.waitForCleanup()
    fixture.systemEvents.emit(.sessionInactive)
    _ = await runtime.waitForCleanup()
    #expect(notices.isEmpty)
    await runtime.stop()
}

@Test(arguments: [RuntimeSystemEvent.sleep, .sessionInactive]) @MainActor
func systemSuspensionReportsOneActualCancellationBeforeCleanupReturns(event: RuntimeSystemEvent) async throws {
    let fixture = RuntimeFixture()
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports())
    await environment.start()
    var notices: [DictationNotice] = []
    let original = environment.runtime.onNotice
    environment.runtime.onNotice = {
        original?($0)
        notices.append($0)
    }
    do {
        try await fixture.beginRecordedTake(in: environment)
        fixture.systemEvents.emit(event)
        fixture.systemEvents.emit(.sleep)
        fixture.systemEvents.emit(.sessionInactive)
        #expect(!environment.runtime.isMonitoring)
        _ = await environment.runtime.waitForCleanup()
        #expect(notices == [.cancelled(.systemEvent)])
        #expect(fixture.inserter.targets.isEmpty)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}
