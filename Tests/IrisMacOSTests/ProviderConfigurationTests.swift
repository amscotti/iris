import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

@Test @MainActor func providerSwitchPublishesMatchingKeyImmediately() async {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    await environment.saveSecret(" meta-test \n", field: "apiKey", provider: "Meta")
    await environment.saveSecret("grok-test", field: "apiKey", provider: "Grok")
    environment.setProvider("Grok")
    #expect(environment.resolvedConfiguration.provider == .grok)
    #expect(environment.resolvedConfiguration.apiKey == "grok-test")
    environment.setProvider("Meta")
    #expect(environment.resolvedConfiguration.provider == .meta)
    #expect(environment.resolvedConfiguration.apiKey == "meta-test")
}

@Test @MainActor func plainSettingsEditsReuseCachedCredentials() async {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    await environment.loadProviderCredentials("Meta")
    let reads = await fixture.secrets.loadCount
    for value in ["English", "French", "German"] {
        environment.setProviderValue(key: "languageBias", value: value)
        _ = await environment.hasSecret(field: "apiKey")
    }
    #expect(await fixture.secrets.loadCount == reads)
}

@Test @MainActor func deniedKeychainReadWaitsForAnExplicitRetry() async {
    actor DeniedStore: SecretStoring {
        private(set) var reads = 0
        func load(key: String) async throws -> String? {
            reads += 1
            throw KeychainError(code: -25293, operation: "load")
        }
        func save(_ value: String, forKey key: String) async throws {}
        func delete(key: String) async throws {}
    }
    let store = DeniedStore()
    let environment = TestEnvironment().make(secretStore: store)
    await environment.loadProviderCredentials("Meta")
    await environment.checkStartupGate(openSettingsWhenBlocked: false)
    environment.setProviderValue(key: "languageBias", value: "French")
    await environment.loadProviderCredentials("Meta")
    #expect(await store.reads == 1)
    await environment.loadProviderCredentials("Meta", retry: true)
    #expect(await store.reads == 2)
}

@Test @MainActor func inactiveProviderEditsDoNotChangeTheActiveRoute() {
    let environment = TestEnvironment().make()
    environment.setProviderValue(key: "languageBias", value: "fr", provider: "Grok")
    environment.setProviderValue(key: "apiKey", value: "never-persist", provider: "Grok")
    #expect(environment.settings.providerName == "Meta")
    #expect(environment.resolvedConfiguration.provider == .meta)
    #expect(environment.settings.providerConfigs["Grok"]?["languageBias"] == "fr")
    #expect(environment.settings.providerConfigs["Grok"]?["apiKey"] == nil)
}

@Test @MainActor func rewriteEditsStayWithTheirProviderAndKeepSpeechVerification() async {
    let connections = ProviderConnections(probe: { _ in })
    let fixture = TestEnvironment()
    let environment = fixture.make(connections: connections)
    await environment.saveSecret("meta-key", field: "apiKey", provider: "Meta")
    await environment.testProviderConnection("Meta")
    #expect(connections.state(for: "Meta") == .connected)
    environment.setProviderValue(key: "rewriteModel", value: "muse-custom", provider: "Meta")
    environment.setProviderValue(key: "rewriteEffort", value: "xhigh", provider: "Grok")
    #expect(connections.state(for: "Meta") == .connected)
    #expect(environment.settings.providerName == "Meta")
    #expect(
        RewriteConfiguration(config: environment.resolvedConfiguration, registry: environment.registry)?.model
            == "muse-custom")
    #expect(
        RewriteConfiguration(config: environment.resolvedConfiguration, registry: environment.registry)?.effort
            == .minimal)
    let relaunched = fixture.make()
    #expect(relaunched.settings.providerConfigs["Meta"]?["rewriteModel"] == "muse-custom")
    #expect(relaunched.settings.providerConfigs["Grok"]?["rewriteEffort"] == "xhigh")
}

@Test @MainActor func speechEditsInvalidateVerificationWhileRewriteEditsKeepItConnected() async throws {
    let fixture = TestEnvironment()
    try await fixture.secrets.save("fixture-meta-key", forKey: "iris.apikey.Meta")
    let client = MockTranscriptionClient()
    let connections = ProviderConnections(probe: { config in
        try await SpeechConnectionProbe.check(
            config, makeService: { _ in TranscriptionService(client: client) })
    })
    let environment = fixture.make(
        connections: connections, registry: AppProviderAssembly.defaultRegistry(),
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true))
    defer { connections.invalidate("Meta") }
    do {
        try await AsyncDeadline.run(seconds: 5) { await environment.testProviderConnection("Meta") }
        #expect(connections.state(for: "Meta") == .connected)
        #expect(client.startCallCount == 1)
        #expect(client.lastConfig?.apiKey == "fixture-meta-key")

        exerciseRewriteEditPreservingVerification(in: environment, client: client)
        try await exerciseSpeechEditAndReverifyConnection(in: environment, client: client)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}

@MainActor
private func exerciseRewriteEditPreservingVerification(
    in environment: AppEnvironment, client: MockTranscriptionClient
) {
    environment.setProviderValue(key: "rewriteModel", value: "muse-custom", provider: "Meta")
    #expect(environment.settings.providerConfigs["Meta"]?["rewriteModel"] == "muse-custom")
    #expect(environment.connections.state(for: "Meta") == .connected)
    #expect(client.startCallCount == 1)
}

@MainActor
private func exerciseSpeechEditAndReverifyConnection(
    in environment: AppEnvironment, client: MockTranscriptionClient
) async throws {
    environment.setProviderValue(key: "languageBias", value: "French", provider: "Meta")
    #expect(environment.connections.state(for: "Meta") == .notChecked)
    #expect(environment.resolvedConfiguration.string("languageBias") == "French")
    #expect(client.startCallCount == 1)
    try await AsyncDeadline.run(seconds: 5) { await environment.testProviderConnection("Meta") }
    #expect(environment.connections.state(for: "Meta") == .connected)
    #expect(client.startCallCount == 2)
    #expect(client.lastConfig?.string("languageBias") == "French")
    #expect(client.lastConfig?.string("rewriteModel") == "muse-custom")
    #expect(client.receivedFrameCount == 0)
    #expect(client.finishCallCount == 0)
}

@Test @MainActor func missingStartupKeyHoldsInputAndSavingItEnablesFreshMonitoring() async throws {
    let fixture = TestEnvironment()
    let runtime = RuntimeFixture()
    let events = TestHotkeyEvents()
    let monitor = GlobalHotkeyMonitor(backend: events)
    let environment = fixture.make(
        registry: AppProviderAssembly.defaultRegistry(),
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: runtime.ports(hotkey: monitor))
    do {
        // Use the real startup gate without presenting/activating a Settings window in unit tests.
        try await AsyncDeadline.run(seconds: 5) {
            await environment.checkStartupGate(openSettingsWhenBlocked: false)
            await environment.runtime.start()
        }
        try await exerciseMissingStartupKeyHold(environment, runtime: runtime, events: events)

        let saved = try await AsyncDeadline.run(seconds: 5) {
            await environment.saveSecret("injected-startup-key", field: "apiKey", provider: "Meta")
        }
        #expect(saved)
        #expect(try await fixture.secrets.load(key: "iris.apikey.Meta") == "injected-startup-key")
        #expect(environment.resolvedConfiguration.apiKey == "injected-startup-key")
        #expect(environment.startupBlockers.isEmpty)
        #expect(!environment.startupLimited)
        #expect(!environment.startupGateHold)
        #expect(!environment.permissionOperationInProgress)
        #expect(environment.runtime.permissionOperationCount == 0)
        #expect(environment.inputState == .ready)
        #expect(environment.runtime.isMonitoring)
        #expect(!environment.runtime.captureSuspended)
        #expect(events.globalHandlers.count == 1)
        #expect(events.localHandlers.count == 1)
        #expect(events.activeTokens.count == 2)
        #expect(events.physicalReads == 1)
        #expect(await runtime.audio.starts == 0)
        #expect(environment.settingsWindowController == nil)
        // An idempotent gate recheck must not install another input generation.
        try await AsyncDeadline.run(seconds: 5) { await environment.checkStartupGate(openSettingsWhenBlocked: false) }
        #expect(events.globalHandlers.count == 1)
        #expect(events.localHandlers.count == 1)
        #expect(events.physicalReads == 1)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
    #expect(!environment.runtime.isMonitoring)
    #expect(events.activeTokens.isEmpty)
    #expect(events.globalHandlers.isEmpty)
    #expect(events.localHandlers.isEmpty)
}

@MainActor
private func exerciseMissingStartupKeyHold(
    _ environment: AppEnvironment, runtime: RuntimeFixture, events: TestHotkeyEvents
) async throws {
    #expect(environment.permissions.microphoneGranted)
    #expect(environment.permissions.accessibilityGranted)
    #expect(environment.startupBlockers == [.apiKey])
    #expect(environment.startupLimited)
    #expect(environment.startupGateHold)
    #expect(environment.runtime.isStarted)
    #expect(environment.inputState == .suspended(.permissionOperation))
    #expect(environment.runtime.captureSuspended)
    #expect(environment.runtime.permissionOperationCount == 1)
    #expect(!environment.permissionOperationInProgress)
    #expect(!environment.runtime.isMonitoring)
    #expect(events.globalHandlers.isEmpty)
    #expect(events.localHandlers.isEmpty)
    #expect(events.physicalReads == 0)
    #expect(await runtime.audio.starts == 0)
    try await AsyncDeadline.run(seconds: 5) { await environment.requestMicrophoneAccess() }
    #expect(!environment.permissionOperationInProgress)
    #expect(environment.runtime.permissionOperationCount == 1)
    #expect(environment.startupGateHold)
    #expect(!environment.runtime.isMonitoring)
}

@Test @MainActor func wireSampleRateMatchesTheCapturerForLegacySettings() {
    let environment = TestEnvironment().make()
    environment.setProviderValue(key: "audioEncoding", value: "PCM_24KHZ")
    #expect(environment.resolvedConfiguration.string("audioEncoding") == "PCM_16KHZ")
}

@Test @MainActor func lastSettingsPaneRestoresFromTheInjectedStore() {
    let fixture = TestEnvironment()
    fixture.make().selectedSettingsTab = .prompts
    #expect(fixture.make().selectedSettingsTab == .prompts)
}

private actor SuspendedSecretStore: SecretStoring {
    private var pending: CheckedContinuation<String?, Never>?
    nonisolated let requests: AsyncStream<String>
    private let requestsContinuation: AsyncStream<String>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: String.self)
        requests = stream.stream
        requestsContinuation = stream.continuation
    }

    func load(key: String) async throws -> String? {
        await withCheckedContinuation { continuation in
            pending = continuation
            requestsContinuation.yield(key)
        }
    }

    func completeLoad(_ value: String) {
        pending?.resume(returning: value)
        pending = nil
    }

    func save(_ value: String, forKey key: String) async throws {}
    func delete(key: String) async throws {}
}

@Test @MainActor func delayedLoadCannotRestoreARemovedAPIKey() async throws {
    let store = SuspendedSecretStore()
    let credentials = ProviderCredentials(store: store)
    var requests = store.requests.makeAsyncIterator()
    let loading = Task { try await credentials.load(provider: "Grok", fields: ["apiKey"]) }
    #expect(await requests.next() == "iris.apikey.Grok")
    try await credentials.remove(provider: "Grok", field: "apiKey")
    await store.completeLoad("stale-key")
    try await loading.value
    #expect(credentials.state(for: "Grok") == .missing)
    #expect(credentials.cachedValues(for: "Grok").isEmpty)
}

@Test @MainActor func delayedLegacyImportCannotRestoreARemovedSecret() async throws {
    let store = SuspendedSecretStore()
    let credentials = ProviderCredentials(store: store)
    var requests = store.requests.makeAsyncIterator()
    let importing = Task {
        try await credentials.importLegacySecret("legacy-session", provider: "Meta", field: "sessionId")
    }
    #expect(await requests.next() == "iris.secret.Meta.sessionId")
    try await credentials.remove(provider: "Meta", field: "sessionId")
    await store.completeLoad("old-session")
    #expect(try await importing.value == false)
    #expect(credentials.cachedValues(for: "Meta")["sessionId"] == nil)
}

@Test @MainActor func failedKeySaveReportsFailureWithoutClaimingItWasSaved() async {
    struct UnwritableStore: SecretStoring {
        func load(key: String) async throws -> String? { nil }
        func save(_ value: String, forKey key: String) async throws {
            throw KeychainError(code: -25293, operation: "save")
        }
        func delete(key: String) async throws { throw KeychainError(code: -25293, operation: "delete") }
    }
    let environment = TestEnvironment().make(secretStore: UnwritableStore())
    #expect(!(await environment.saveSecret("test", field: "apiKey", provider: "Grok")))
    #expect(environment.credentialErrors["Grok"] != nil)
    #expect(environment.credentials.state(for: "Grok") != .saved)
}

@Test @MainActor func firstKeyForAnotherProviderMakesItActiveWhenTheActiveOneHasNone() async {
    let environment = TestEnvironment().make()
    await environment.loadProviderCredentials("Meta")
    #expect(environment.settings.providerName == "Meta")
    await environment.saveSecret("grok-key", field: "apiKey", provider: "Grok")
    #expect(environment.settings.providerName == "Grok")
}

@Test @MainActor func savingAnotherProvidersKeyKeepsAConfiguredActiveProvider() async {
    let environment = TestEnvironment().make()
    await environment.saveSecret("meta-key", field: "apiKey", provider: "Meta")
    await environment.saveSecret("grok-key", field: "apiKey", provider: "Grok")
    #expect(environment.settings.providerName == "Meta")
}
