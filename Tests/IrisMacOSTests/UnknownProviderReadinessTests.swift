import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func unknownPersistedProviderBlocksReadinessInsteadOfPretendingReady() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("old-key", forKey: SecretStoreKeys.key(providerName: "Future"))
    let environment = fixture.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        defaults: AppSettings(providerName: "Future"))

    await environment.checkStartupGate(openSettingsWhenBlocked: false)

    #expect(environment.startupLimited)
    #expect(environment.startupBlockers == [.providerUnavailable])
    #expect(environment.menuStartupBlockers == [.providerUnavailable])
    #expect(environment.runtime.captureSuspended)
    #expect(environment.settingsLoadIssue == nil)
    #expect(environment.settings.providerName == "Future")
    await environment.stop()
}

@Test @MainActor func liveUnknownRouteSynchronouslySuspendsInputEvenWithCachedKey() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("meta-key", forKey: "iris.apikey.Meta")
    try await fixture.secrets.save("future-key", forKey: "iris.apikey.Future")
    let environment = fixture.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true))
    await environment.start()
    #expect(environment.runtime.isMonitoring)

    var updated = environment.settings
    updated.providerName = "Future"
    environment.saveSettings(updated)

    #expect(!environment.runtime.isMonitoring)
    await environment.checkStartupGate(openSettingsWhenBlocked: false)
    #expect(environment.startupLimited)
    #expect(environment.startupBlockers == [.providerUnavailable])
    await environment.stop()
}

@Test func providerAvailabilityIsAnIndependentReadinessRequirement() {
    let readiness = StartupReadiness(
        microphoneGranted: true, accessibilityGranted: true, apiKeyPresent: true, providerAvailable: false)
    #expect(!readiness.isReady)
    #expect(readiness.missingItems == [.providerUnavailable])
}
