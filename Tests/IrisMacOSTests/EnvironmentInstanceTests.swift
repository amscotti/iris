import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

@Test @MainActor func settingsWindowUsesCompatibleAccessoryBehaviors() {
    // Construct only: unit tests never order or activate a real window.
    let settings = SettingsWindowController.makeWindow()
    #expect(settings.canBecomeKey)
    #expect(settings.identifier == SettingsWindowController.windowIdentifier)
    #expect(!settings.hidesOnDeactivate)
    let pill = PillPanel()
    #expect(!pill.hidesOnDeactivate)
    #expect(!settings.isReleasedWhenClosed)
    #expect(settings.level == .normal)
    #expect(settings.collectionBehavior.contains(.moveToActiveSpace))
    #expect(!settings.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(!settings.styleMask.contains(.miniaturizable))
}

@Test @MainActor func environmentExposesReadinessAndSecretKeys() async throws {
    let environment = TestEnvironment().make()
    #expect(try SecretStoreKeys.key(providerName: "Meta") == "iris.apikey.Meta")
    #expect(try SecretStoreKeys.key(providerName: "Meta", field: "token") == "iris.secret.Meta.token")
    let readiness = environment.readiness(apiKeyPresent: true)
    #expect(readiness.missingItems.contains(.microphone))
    #expect(readiness.missingItems.contains(.accessibility))
}

@Test @MainActor func startupGateMarksBlockersWithoutOpeningSettings() async {
    let environment = TestEnvironment().make()
    #expect(environment.selectedSettingsTab == .providers)
    await environment.checkStartupGate(openSettingsWhenBlocked: false)
    #expect(environment.startupLimited)
    #expect(environment.startupBlockers.contains(.microphone))
    #expect(environment.startupBlockers.contains(.accessibility))
    #expect(environment.statusLine == "Iris setup needed")
    #expect(environment.menuSymbol == "exclamationmark.triangle")
    #expect(environment.selectedSettingsTab == .providers)
    // The blocked gate holds a runtime suspension, but that hold must not
    // disable the permission controls the user needs to clear the blockers.
    #expect(!environment.permissionOperationInProgress)
}

@Test @MainActor func unreadableSettingsBlockDictation() async throws {
    let fixture = TestEnvironment()
    try fixture.persistence.save(Data("not-json".utf8), forKey: AppSettings.storageKey)
    let permissions = PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true)
    let environment = fixture.make(permissions: permissions)
    await environment.saveSecret("stored-key", field: "apiKey", provider: environment.settings.providerName)
    await environment.checkStartupGate(openSettingsWhenBlocked: false)
    #expect(environment.settingsLoadIssue != nil)
    #expect(environment.startupLimited)
    #expect(environment.statusLine == "Settings could not be read")
}

@Test @MainActor func legacyPlaintextSecretsMoveIntoTheKeychain() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(
        providerName: "Meta",
        providerConfigs: ["Meta": ["apiKey": "legacy-key", "language": "en"]])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()
    await environment.importPlaintextSecrets()
    #expect(environment.settings.providerConfigs["Meta"]?["apiKey"] == nil)
    #expect(environment.settings.providerConfigs["Meta"]?["language"] == "en")
    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta")) == "legacy-key")
}

@Test @MainActor func legacyPlaintextSecretsKeepAnExistingKeychainValue() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("existing-key", forKey: SecretStoreKeys.key(providerName: "Meta"))
    let stored = AppSettings(
        providerName: "Meta", providerConfigs: ["Meta": ["apiKey": "legacy-key", "language": "en"]])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()
    await environment.importPlaintextSecrets()
    #expect(try await fixture.secrets.load(key: SecretStoreKeys.key(providerName: "Meta")) == "existing-key")
    #expect(environment.settings.providerConfigs["Meta"]?["apiKey"] == nil)
    #expect(environment.settings.providerConfigs["Meta"]?["language"] == "en")
}

@Test @MainActor func legacyPlaintextSecretsStayWhenTheKeychainCannotBeRead() async throws {
    let fixture = TestEnvironment()
    await fixture.secrets.failLoads(true)
    let stored = AppSettings(
        providerName: "Meta", providerConfigs: ["Meta": ["apiKey": "legacy-key", "language": "en"]])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()
    await environment.importPlaintextSecrets()
    #expect(environment.settings.providerConfigs["Meta"]?["apiKey"] == "legacy-key")
    #expect(environment.settings.providerConfigs["Meta"]?["language"] == "en")
}

@Test @MainActor func environmentUsesOnlyTheInjectedSecretStore() async throws {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    await environment.saveSecret("test-only", field: "apiKey", provider: "Grok")
    #expect(try await fixture.secrets.load(key: "iris.apikey.Grok") == "test-only")
    #expect(await environment.hasSecret(field: "apiKey", provider: "Grok"))
    #expect(!(await environment.hasSecret(field: "apiKey", provider: "Meta")))
    await environment.clearSecret(field: "apiKey", provider: "Grok")
    #expect(try await fixture.secrets.load(key: "iris.apikey.Grok") == nil)
}

@Test @MainActor func dictationErrorRemainsVisibleUntilANewTake() {
    let environment = TestEnvironment().make()
    environment.handleStatus(.error("Provider rejected the API key."))
    environment.handleStatus(.idle)
    #expect(environment.lastDictationError == "Provider rejected the API key.")
    #expect(environment.menuSymbol == "exclamationmark.triangle")
    environment.handleStatus(.recording(level: 0))
    #expect(environment.lastDictationError == nil)
}

@Test @MainActor func emptyTranscriptExplainsWhyNothingWasInserted() {
    let environment = TestEnvironment().make()
    environment.handleStatus(.final(""))
    environment.handleStatus(.idle)
    #expect(environment.lastDictationError?.contains("No speech was recognized") == true)
}

@Test @MainActor func saveSettingsScrubsSecretProviderValues() {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    var updated = environment.settings
    updated.providerName = ProviderID.meta.name
    updated.providerValues = [
        ProviderConfiguration.Key.model: "kept-model",
        ProviderConfiguration.Key.apiKey: "sk-must-not-persist",
    ]
    environment.saveSettings(updated)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.apiKey] == nil)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.model] == "kept-model")
    let relaunched = fixture.make()
    #expect(relaunched.settings.providerValues[ProviderConfiguration.Key.apiKey] == nil)
    #expect(relaunched.settings.providerValues[ProviderConfiguration.Key.model] == "kept-model")
}

@Test @MainActor func setProviderValueIgnoresSecretsAndKeepsPlainFields() {
    let environment = TestEnvironment().make()
    environment.setProvider(ProviderID.meta.name)
    environment.setProviderValue(key: ProviderConfiguration.Key.apiKey, value: "sk-must-not-persist")
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.apiKey] == nil)
    environment.setProviderValue(key: ProviderConfiguration.Key.model, value: "future-model")
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.model] == "future-model")
}

@Test @MainActor func setProviderKeepsEachProvidersValues() {
    let environment = TestEnvironment().make()
    environment.setProvider(ProviderID.meta.name)
    environment.setProviderValue(key: ProviderConfiguration.Key.model, value: "future-model")
    // A first visit opens an empty namespace: defaults are supplied at read
    // time (descriptor merge), never frozen into stored values — a later
    // default change still reaches the user.
    environment.setProvider(ProviderID.mock.name)
    #expect(environment.settings.providerName == ProviderID.mock.name)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.model] == nil)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.apiKey] == nil)
    #expect(environment.settings.providerValues["script"] == nil)
    #expect(environment.settings.providerValues["autoFinal"] == nil)
    environment.setProvider(ProviderID.grok.name)
    #expect(environment.settings.providerName == ProviderID.grok.name)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.model] == nil)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.languageBias] == nil)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.keywords] == nil)
    #expect(environment.settings.providerValues["script"] == nil)
    // Switching back restores what each provider had, so a failover to the
    // other service and back loses nothing.
    environment.setProvider(ProviderID.meta.name)
    #expect(environment.settings.providerValues[ProviderConfiguration.Key.model] == "future-model")
    environment.setProvider(ProviderID.mock.name)
    #expect(environment.settings.providerValues["script"] == nil)
}

@Test @MainActor func providerSwitchPreservesSharedPromptsAndIndependentRewriteSettings() {
    let environment = TestEnvironment().make()
    environment.setProviderValue(key: "rewriteModel", value: "muse-custom", provider: "Meta")
    environment.setProviderValue(key: "rewriteEffort", value: "minimal", provider: "Meta")
    environment.setProviderValue(key: "rewriteModel", value: "grok-custom", provider: "Grok")
    environment.setProviderValue(key: "rewriteEffort", value: "xhigh", provider: "Grok")
    let created = environment.addPrompt()
    environment.selectPrompt(id: created.id)
    let prompts = environment.settings.prompts
    environment.setProvider(ProviderID.grok.name)
    #expect(
        RewriteConfiguration(config: environment.resolvedConfiguration, registry: environment.registry)?.model
            == "grok-custom")
    #expect(
        RewriteConfiguration(config: environment.resolvedConfiguration, registry: environment.registry)?.effort
            == .xhigh)
    #expect(environment.settings.prompts == prompts)
    #expect(environment.selectedPromptID == created.id)
    environment.setProvider(ProviderID.meta.name)
    #expect(
        RewriteConfiguration(config: environment.resolvedConfiguration, registry: environment.registry)?.model
            == "muse-custom")
    #expect(
        RewriteConfiguration(config: environment.resolvedConfiguration, registry: environment.registry)?.effort
            == .minimal)
    #expect(environment.settings.prompts == prompts)
    #expect(environment.selectedPromptID == created.id)
}

@Test @MainActor func keylessProviderReportsSavedAfterLoad() async {
    // A provider whose descriptor declares no secret fields must not be
    // permanently "Needs API key" (regression: empty `required` meant missing).
    let environment = TestEnvironment().make()
    await environment.loadProviderCredentials("mock")
    #expect(environment.credentials.state(for: "mock") == .saved)
}

@Test @MainActor func emptyFinalNoticeSurvivesTheTrailingIdleSnapshot() async {
    let environment = TestEnvironment().make()
    // The service emits .final("") then .idle; the notice set by the final
    // must not be clobbered by the idle snapshot that follows it.
    environment.handleSnapshot(
        DictationSnapshot(
            state: .final(""), lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("")))
    #expect(environment.lastDictationError?.contains("No speech was recognized") == true)
    environment.handleSnapshot(
        DictationSnapshot(
            state: .idle, lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("")))
    #expect(environment.lastDictationError?.contains("No speech was recognized") == true)
    // The next take clears it.
    environment.handleSnapshot(
        DictationSnapshot(
            state: .recording(level: 0), lastError: nil, requiresRestart: false,
            terminalRevision: 1, lastTerminal: .final("")))
    #expect(environment.lastDictationError == nil)
}

@Test @MainActor func settingsErrorSentencesDoNotDoublePunctuate() {
    #expect(SettingsController.sentence("boom") == "boom.")
    #expect(SettingsController.sentence("boom.") == "boom.")
    #expect(SettingsController.sentence("failed (error 1.)") == "failed (error 1.)")
    #expect(SettingsController.sentence("") == "")
}

@Test @MainActor func migratedSessionSecretResolvesAfterRelaunch() async throws {
    let fixture = TestEnvironment()
    let stored = AppSettings(
        providerName: "Meta", providerValues: ["apiKey": "legacy-key", "sessionId": "legacy-session"])
    try stored.save(to: fixture.persistence)
    let environment = fixture.make()
    await environment.importPlaintextSecrets()
    #expect(environment.resolvedConfiguration.string("sessionId") == "legacy-session")

    let relaunched = fixture.make()
    await relaunched.loadProviderCredentials("Meta")
    #expect(relaunched.resolvedConfiguration.string("sessionId") == "legacy-session")
    await relaunched.stop()
}

@Test @MainActor func startupGateRequiresEveryDescriptorSecretEvenWithoutALoad() async {
    var registry = ProviderRegistry()
    registry.register(ControllerProviderFixture())
    let fixture = TestEnvironment()
    let defaults = AppSettings(providerName: "Credential fixture")
    let environment = fixture.make(
        registry: registry,
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        defaults: defaults)
    await environment.saveSecret("fixture-api-key", field: "apiKey", provider: "Credential fixture")
    await environment.checkStartupGate(openSettingsWhenBlocked: false)
    #expect(environment.startupBlockers == [.apiKey])
    await environment.saveSecret("fixture-token", field: "token", provider: "Credential fixture")
    await environment.checkStartupGate(openSettingsWhenBlocked: false)
    #expect(!environment.startupLimited)
    await environment.stop()
}

private actor GateSuspendingSecretStore: SecretStoring {
    private var pending: [String: CheckedContinuation<String?, Never>] = [:]
    nonisolated let requests: AsyncStream<String>
    private let requestsContinuation: AsyncStream<String>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: String.self)
        requests = stream.stream
        requestsContinuation = stream.continuation
    }

    func load(key: String) async throws -> String? {
        await withCheckedContinuation { continuation in
            pending[key] = continuation
            requestsContinuation.yield(key)
        }
    }

    func completeLoad(key: String, value: String?) {
        pending.removeValue(forKey: key)?.resume(returning: value)
    }

    func save(_ value: String, forKey key: String) async throws {}
    func delete(key: String) async throws {}
}

@Test @MainActor func supersededLaunchCheckStillOpensSettingsExactlyOnce() async throws {
    let store = GateSuspendingSecretStore()
    let fixture = TestEnvironment()
    let environment = fixture.make(secretStore: store)
    var requests = store.requests.makeAsyncIterator()
    let launchCheck = Task { await environment.checkStartupGate(openSettingsWhenBlocked: true) }
    #expect(await requests.next() == "iris.apikey.Meta")

    let silentRecheck = Task { await environment.checkStartupGate(openSettingsWhenBlocked: false) }
    do {
        try await AsyncDeadline.run(seconds: 5) { @MainActor in
            while environment.startupGateGeneration < 2 { await Task.yield() }
        }
    } catch {
        Issue.record("The silent re-check never started.")
    }
    #expect(environment.settingsWindowController == nil)

    await store.completeLoad(key: "iris.apikey.Meta", value: nil)
    #expect(await requests.next() == "iris.secret.Meta.sessionId")
    await store.completeLoad(key: "iris.secret.Meta.sessionId", value: nil)
    await launchCheck.value
    await silentRecheck.value

    #expect(environment.startupLimited)
    #expect(environment.selectedSettingsTab == .permissions)
    #expect(environment.settingsWindowController != nil)
    await environment.stop()
}

@Test @MainActor func launchCheckAbortedByAProviderSwitchDoesNotLeakTheOpenSettingsLatch() async throws {
    let store = GateSuspendingSecretStore()
    let fixture = TestEnvironment()
    let environment = fixture.make(secretStore: store)
    var requests = store.requests.makeAsyncIterator()
    let launchCheck = Task { await environment.checkStartupGate(openSettingsWhenBlocked: true) }
    #expect(await requests.next() == "iris.apikey.Meta")

    // The provider switches while the launch check is parked on its
    // Keychain read. The implicit re-check is suppressed so this test can
    // drive the follow-up silent check deterministically.
    environment.suppressStartupGateRecheck = true
    environment.setProvider("Grok")
    environment.suppressStartupGateRecheck = false
    let silentRecheck = Task { await environment.checkStartupGate(openSettingsWhenBlocked: false) }
    #expect(await requests.next() == "iris.apikey.Grok")

    // Resuming the aborted launch check: its provider no longer matches, so
    // it must exit without keeping the open-Settings latch it set.
    await store.completeLoad(key: "iris.apikey.Meta", value: nil)
    #expect(await requests.next() == "iris.secret.Meta.sessionId")
    await store.completeLoad(key: "iris.secret.Meta.sessionId", value: nil)
    await launchCheck.value

    // The new provider's silent check is still blocked (no key saved), but
    // Settings must not pop open: the launch intent died with the switch.
    await store.completeLoad(key: "iris.apikey.Grok", value: nil)
    #expect(await requests.next() == "iris.secret.Grok.sessionId")
    await store.completeLoad(key: "iris.secret.Grok.sessionId", value: nil)
    await silentRecheck.value

    #expect(environment.startupLimited)
    #expect(environment.startupBlockers.contains(.apiKey))
    #expect(environment.settingsWindowController == nil)
    await environment.stop()
}

@Test @MainActor func dictationHintNamesTheShortcutModeAndProvider() {
    let environment = TestEnvironment().make()
    #expect(environment.dictationHint == "Hold Right Option to dictate with Meta; release to finish")
    var toggled = environment.settings
    toggled.hotkey = HotkeyConfiguration(keyCode: 54, modifiers: 0, mode: .toggle)
    environment.saveSettings(toggled)
    #expect(environment.dictationHint == "Press Right Command to dictate with Meta; press again to finish")
}
