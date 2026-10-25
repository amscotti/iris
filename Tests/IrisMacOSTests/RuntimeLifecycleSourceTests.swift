import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@MainActor
private func makeLifecycleEnvironment() async throws -> AppEnvironment {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = fixture.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: RuntimeFixture().ports())
    await environment.start()
    return environment
}

@Test @MainActor func sessionActivationCannotClearScreenLock() async throws {
    let environment = try await makeLifecycleEnvironment()
    do {
        environment.runtime.handle(.screenLocked)
        #expect(!environment.inputState.isReady)
        #expect(!environment.runtime.isMonitoring)

        environment.runtime.handle(.sessionActive)
        #expect(!environment.inputState.isReady)
        #expect(!environment.runtime.isMonitoring)

        environment.runtime.handle(.screenUnlocked)
        _ = try await AsyncDeadline.run(seconds: 5) { await environment.runtime.waitForCleanup() }
        environment.runtime.handle(.refresh)
        #expect(environment.inputState == .ready)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}

@Test @MainActor func displayWakeCannotClearSystemSleep() async throws {
    let environment = try await makeLifecycleEnvironment()
    do {
        environment.runtime.handle(.sleep)
        #expect(!environment.inputState.isReady)
        environment.runtime.handle(.displayWake)
        #expect(!environment.inputState.isReady)
        #expect(!environment.runtime.isMonitoring)

        environment.runtime.handle(.wake)
        _ = try await AsyncDeadline.run(seconds: 5) { await environment.runtime.waitForCleanup() }
        environment.runtime.handle(.refresh)
        #expect(environment.inputState == .ready)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}
