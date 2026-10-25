import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func promptOnlyEditsDoNotRefreshCredentials() {
    let controller = SettingsController(
        persistence: TestSettingsStore(), registry: ProviderRegistry(), defaults: .defaults)
    var changes: [SettingsController.Change] = []
    controller.onChange = { changes.append($0) }
    let created = controller.addPrompt()
    #expect(changes.last?.invalidatedProviders.isEmpty == true)
    #expect(changes.last?.refreshCredentials == false)
    var edited = created
    edited.template = "Tidy:\n\n{{transcript}}"
    controller.updatePrompt(edited)
    #expect(changes.last?.refreshCredentials == false)
    controller.selectPrompt(id: created.id)
    #expect(changes.last?.refreshCredentials == false)
    controller.setProviderValue(key: "model", value: "m1", provider: "Meta")
    #expect(changes.last?.refreshCredentials == true)
    var switched = controller.settings
    switched.providerName = "Grok"
    controller.save(switched)
    #expect(changes.last?.refreshCredentials == true)
}

@Test @MainActor func controllerRecoveryUsesInjectedDefaultsAndPreservesUnreadableBytes() throws {
    let store = TestSettingsStore()
    let defaults = AppSettings(providerName: "Application default", trailingSpace: false)
    let raw = Data(#"{"schemaVersion":999,"providerName":"Keep this provider"}"#.utf8)
    try store.save(raw, forKey: AppSettings.storageKey)
    let controller = SettingsController(persistence: store, registry: ProviderRegistry(), defaults: defaults)
    #expect(controller.settings == defaults)
    #expect(controller.loadIssue != nil)
    #expect(controller.canRecover)
    controller.setProviderValue(key: "model", value: "memory-only", provider: defaults.providerName)
    #expect(controller.saveError != nil)
    #expect(try store.load(key: AppSettings.storageKey) == raw)
    controller.recover()
    #expect(controller.settings == defaults)
    #expect(controller.loadIssue == nil)
    #expect(controller.saveError == nil)
    try expectRecoveryBackupPlaceholder(store, original: raw)
    #expect(try AppSettings.load(from: store) == defaults)
}

@Test @MainActor func controllerRecoveryRetainsItsIssueAndRawSettingsWhenBackupFailsThenRetries() throws {
    let store = BackupFailingSettingsStore()
    let defaults = AppSettings(providerName: "Application default", trailingSpace: false)
    let raw = Data(#"{"schemaVersion":999,"providerName":"Keep these unreadable settings"}"#.utf8)
    try store.save(raw, forKey: AppSettings.storageKey)
    let controller = SettingsController(persistence: store, registry: ProviderRegistry(), defaults: defaults)
    let issue = try #require(controller.loadIssue)
    controller.setProviderValue(key: "model", value: "memory-only", provider: defaults.providerName)
    let beforeRecovery = controller.settings
    #expect(beforeRecovery != defaults)
    var changes: [SettingsController.Change] = []
    controller.onChange = { changes.append($0) }
    store.failBackupWrites = true
    let previousAttempts = store.writeKeys.count

    controller.recover()

    #expect(Array(store.writeKeys.dropFirst(previousAttempts)) == [SettingsRepository.backupKey])
    #expect(try store.load(key: AppSettings.storageKey) == raw)
    #expect(try store.load(key: SettingsRepository.backupKey) == nil)
    #expect(controller.settings == beforeRecovery)
    #expect(controller.loadIssue == issue)
    #expect(controller.canRecover)
    #expect(
        controller.saveError
            == "Settings recovery failed. Backup write was refused. Saved settings are unchanged.")
    #expect(changes.isEmpty)

    store.failBackupWrites = false
    controller.recover()

    try expectRecoveryBackupPlaceholder(store, original: raw)
    #expect(try AppSettings.load(from: store) == defaults)
    #expect(controller.settings == defaults)
    #expect(controller.loadIssue == nil)
    #expect(controller.saveError == nil)
    #expect(!controller.canRecover)
    #expect(changes.count == 1)
    #expect(changes.first?.invalidatedProviders == [defaults.providerName])
    #expect(changes.first?.refreshCredentials == true)
}

@Test @MainActor func missingSettingsUseCompositionDefaultsWithoutChangingLegacyDecode() throws {
    let store = TestSettingsStore()
    let defaults = AppSettings(providerName: "Application default", trailingSpace: false)
    let controller = SettingsController(persistence: store, registry: ProviderRegistry(), defaults: defaults)
    #expect(controller.settings == defaults)
    #expect(try store.load(key: AppSettings.storageKey) == nil)
    try store.save(Data("{}".utf8), forKey: AppSettings.storageKey)
    controller.retryLoad()
    #expect(controller.settings.providerName == AppSettings.legacyProviderName)
    #expect(controller.settings.trailingSpace)
    let migrated = try #require(try store.load(key: AppSettings.storageKey))
    #expect(SettingsRepository.peekSchemaVersion(migrated) == SettingsRepository.currentVersion)
}

@Test @MainActor func failedSettingsSaveStillPublishesScrubbedConfigurationAndCanBeRetried() throws {
    let store = TestSettingsStore()
    var registry = ProviderRegistry()
    registry.register(ControllerProviderFixture())
    let controller = SettingsController(persistence: store, registry: registry, defaults: .defaults)
    var changes: [SettingsController.Change] = []
    controller.onChange = { changes.append($0) }
    var edited = controller.settings
    edited.providerConfigs = [
        "Credential fixture": ["apiKey": "not-plain", "token": "not-plain", "model": "new-model"],
        "Unregistered": ["apiKey": "not-plain", "sessionId": "not-plain", "future": "keep"],
    ]
    store.failWrites = true
    controller.save(edited)
    #expect(controller.settings.providerConfigs["Credential fixture"] == ["model": "new-model"])
    #expect(controller.settings.providerConfigs["Unregistered"] == ["future": "keep"])
    #expect(controller.saveError?.contains("Changes apply until Iris quits") == true)
    #expect(changes.last?.invalidatedProviders == ["Credential fixture", "Unregistered"])
    #expect(changes.last?.refreshCredentials == true)
    #expect(try store.load(key: AppSettings.storageKey) == nil)
    store.failWrites = false
    controller.save(controller.settings)
    #expect(controller.saveError == nil)
    #expect(try AppSettings.load(from: store) == controller.settings)
    #expect(changes.last?.invalidatedProviders.isEmpty == true)
}

@Test @MainActor func controllerRetryDoesNotStampLegacyChoicesWithoutARewriteDescriptor() throws {
    let store = TestSettingsStore()
    let raw = Data(
        #"{"schemaVersion":1,"providerName":"Unregistered","prompts":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","template":"Keep this","model":"legacy-model","effort":"high"}]}"#
            .utf8)
    try store.save(raw, forKey: AppSettings.storageKey)
    let controller = SettingsController(persistence: store, registry: ProviderRegistry(), defaults: .defaults)
    controller.retryLoad()
    #expect(controller.loadIssue == nil)
    #expect(controller.settings.schemaVersion == 1)
    #expect(controller.settings.prompts.first?.template == "Keep this")
    #expect(try store.load(key: AppSettings.storageKey) == raw)
}

@Test @MainActor func removedSpeechNamespacesInvalidateButRewriteAndPromptEditsDoNot() {
    let store = TestSettingsStore()
    let defaults = AppSettings(providerConfigs: ["Existing": ["model": "old"]])
    let controller = SettingsController(persistence: store, registry: ProviderRegistry(), defaults: defaults)
    var changes: [SettingsController.Change] = []
    controller.onChange = { changes.append($0) }
    controller.setProviderValue(key: "rewriteModel", value: "new-rewriter", provider: "Existing")
    #expect(changes.last?.invalidatedProviders.isEmpty == true)
    let prompt = controller.addPrompt()
    controller.selectPrompt(id: prompt.id)
    #expect(changes.last?.invalidatedProviders.isEmpty == true)
    var edited = controller.settings
    edited.providerConfigs.removeValue(forKey: "Existing")
    controller.save(edited)
    #expect(changes.last?.invalidatedProviders == ["Existing"])
    #expect(controller.selectedPromptID == prompt.id)
}

@Test @MainActor func renamingASpeechNamespacePublishesBothRemovedAndAddedProviders() throws {
    let store = TestSettingsStore()
    let values = ["languageBias": "French", "rewriteModel": "shared-rewriter"]
    let defaults = AppSettings(providerName: "Meta", providerConfigs: ["Meta": values])
    let controller = SettingsController(
        persistence: store, registry: AppProviderAssembly.defaultRegistry(), defaults: defaults)
    var changes: [SettingsController.Change] = []
    controller.onChange = { changes.append($0) }
    var renamed = controller.settings
    renamed.providerName = "Grok"
    let removedValues = renamed.providerConfigs.removeValue(forKey: "Meta")
    let renamedValues = try #require(removedValues)
    renamed.providerConfigs["Grok"] = renamedValues

    controller.save(renamed)

    #expect(controller.saveError == nil)
    #expect(controller.settings.providerConfigs["Meta"] == nil)
    #expect(controller.settings.providerConfigs["Grok"] == values)
    #expect(changes.count == 1)
    let change = try #require(changes.first)
    #expect(change.invalidatedProviders == ["Meta", "Grok"])
    #expect(change.refreshCredentials)
    #expect(try AppSettings.load(from: store) == renamed)
}

@Test @MainActor func controllerReadRetryRestoresSavedSettingsWithoutAnUnnecessaryWrite() throws {
    let store = TestSettingsStore()
    let saved = AppSettings(providerName: "Saved provider", prompts: [PromptDefinition(template: "Keep me")])
    try saved.save(to: store)
    let original = try store.load(key: AppSettings.storageKey)
    store.failReads = true
    let controller = SettingsController(persistence: store, registry: ProviderRegistry(), defaults: .defaults)
    #expect(controller.loadIssue != nil)
    #expect(!controller.canRecover)
    controller.setProviderValue(key: "model", value: "not-saved", provider: "Meta")
    #expect(controller.saveError != nil)
    store.failReads = false
    store.failWrites = true
    controller.retryLoad()
    #expect(controller.loadIssue == nil)
    #expect(controller.saveError == nil)
    #expect(controller.settings == saved)
    #expect(try store.load(key: AppSettings.storageKey) == original)
    store.failWrites = false
    controller.save(controller.settings)
    #expect(controller.saveError == nil)
}

@Test @MainActor func settingsClipboardCommandsUseOnlyTheirInjectedPort() {
    let clipboard = FakeClipboard(string: "fixture clipboard")
    let environment = TestEnvironment().make(clipboard: clipboard)
    #expect(environment.readClipboardText() == "fixture clipboard")
    #expect(environment.copyTextToClipboard("new clipboard"))
    #expect(clipboard.string() == "new clipboard")
    clipboard.setSucceeds = false
    #expect(!environment.copyTextToClipboard("failed write"))
    #expect(environment.readClipboardText() == "new clipboard")
}

/// Only backup writes fail; an accidental primary-settings overwrite would succeed and be observable.
private final class BackupFailingSettingsStore: PersistenceProviding, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case backupWrite
        var errorDescription: String? { "Backup write was refused." }
    }

    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var backupWritesFail = false
    private var attemptedKeys: [String] = []

    var failBackupWrites: Bool {
        get { lock.withLock { backupWritesFail } }
        set { lock.withLock { backupWritesFail = newValue } }
    }
    var writeKeys: [String] { lock.withLock { attemptedKeys } }

    func load(key: String) throws -> Data? { lock.withLock { values[key] } }
    func save(_ data: Data, forKey key: String) throws {
        try lock.withLock {
            attemptedKeys.append(key)
            if backupWritesFail, key.hasPrefix(SettingsRepository.backupKey) { throw Failure.backupWrite }
            values[key] = data
        }
    }
    func delete(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
