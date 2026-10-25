import ApplicationServices
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

private func gate(
    permissions: PermissionSnapshot, microphone: @escaping @Sendable () -> Bool,
    accessibility: @escaping @Sendable () -> Bool, image: @escaping @Sendable () -> Bool
) -> DictationOrchestrator.BeginGate {
    RuntimeGate.make(
        permissions: permissions,
        authorization: CaptureAuthorization(microphone: microphone, accessibility: accessibility, image: image))
}

@Test @MainActor func pressGateRefusesWithoutMicrophone() async {
    let permissions = PermissionSnapshot()
    permissions.microphoneGranted = false
    let gate = gate(permissions: permissions, microphone: { false }, accessibility: { true }, image: { true })
    #expect(await gate() == "Microphone access is off. Enable it in Settings to dictate.")
}

@Test @MainActor func pressGateChecksAccessibilitySecond() async {
    let permissions = PermissionSnapshot()
    permissions.microphoneGranted = true
    let gate = gate(permissions: permissions, microphone: { true }, accessibility: { false }, image: { true })
    #expect(await gate() == "Accessibility access is off. Enable it in Settings to dictate.")
}

@Test @MainActor func pressGateRechecksMicrophoneInsteadOfTrustingTheIdleCache() async {
    let permissions = PermissionSnapshot()
    permissions.microphoneGranted = true
    let gate = gate(permissions: permissions, microphone: { false }, accessibility: { true }, image: { true })
    #expect(await gate() == "Microphone access is off. Enable it in Settings to dictate.")
    #expect(!permissions.microphoneGranted)
}

@Test @MainActor func shortcutTryItMessageReflectsRestartState() {
    #expect(
        ShortcutTab.tryItMessage(requiresRelaunch: true)
            == "Iris is waiting for a restart; dictation is paused until then.")
    #expect(
        ShortcutTab.tryItMessage(requiresRelaunch: false)
            == "Place the cursor in a text field in another app, then use your shortcut.")
}

@Test @MainActor func suspendedPressGateSkipsCodeSignatureCheck() async {
    let permissions = PermissionSnapshot()
    permissions.captureSuspended = true
    let gate = gate(
        permissions: permissions, microphone: { true }, accessibility: { true },
        image: {
            Issue.record("Paused presses must not pay code-signature IPC")
            return false
        })
    #expect(await gate() == "Dictation is paused while permissions or the login session change.")
    #expect(!permissions.requiresRelaunch)
}

@Test @MainActor func changedExecutableRefusesCaptureBeforeMicrophoneAccess() async {
    let permissions = PermissionSnapshot()
    let gate = gate(
        permissions: permissions,
        microphone: {
            Issue.record("Must not touch capture after a build changed")
            return true
        },
        accessibility: { true }, image: { false })
    #expect(await gate() == ApplicationImage.changedMessage)
    #expect(permissions.requiresRelaunch)
    #expect(permissions.captureSuspended)
}

@Test @MainActor func serviceFactoryBuildsAnIdleServicePerProvider() async {
    let registry = AppProviderAssembly.defaultRegistry()
    let factory = AppComposition.makeServiceFactory(registry: registry)
    let mockService = factory(ProviderConfiguration(provider: .mock, values: [:]))
    #expect(await mockService.currentState == .idle)
    let metaService = factory(ProviderConfiguration(provider: .meta, values: [:]))
    #expect(await metaService.currentState == .idle)
    let grokService = factory(ProviderConfiguration(provider: .grok, values: ["apiKey": "k"]))
    #expect(await grokService.currentState == .idle)
    #expect(
        registry.provider(for: .grok)?.completionPolicy(for: ProviderConfiguration(provider: .grok))
            == .finalEvent)
}

@Test @MainActor func pressBoxPublishesTheLatestSnapshot() {
    let config = ProviderConfiguration(provider: .mock, values: ["key": "value"])
    let box = PressConfigurationBox(
        settings: .defaults, config: config)
    #expect(box.current().config == config)
    #expect(box.current().settings == .defaults)
    var updated = AppSettings.defaults
    updated.trailingSpace = false
    let updatedConfig = ProviderConfiguration(provider: .mock, values: [:])
    box.update(settings: updated, config: updatedConfig)
    #expect(box.current().settings.trailingSpace == false)
    #expect(box.current().config == updatedConfig)
}

@Test @MainActor func discardedTransportAbsorbsTraffic() async throws {
    let transport = DiscardedTransport()
    try await transport.connect()
    try await transport.write(Data([1, 2, 3]))
    var count = 0
    for try await _ in transport.messages() {
        count += 1
    }
    #expect(count == 0)
    await transport.close()
}
