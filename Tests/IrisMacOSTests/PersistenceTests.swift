import Foundation
import IrisProviders
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func userDefaultsPersistenceRoundTrips() throws {
    let name = "io.github.amscotti.iris.tests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let persistence = UserDefaultsPersistence(defaults: suite)
    #expect(try persistence.load(key: "key") == nil)
    try persistence.save(Data([1, 2, 3]), forKey: "key")
    #expect(try persistence.load(key: "key") == Data([1, 2, 3]))
    try persistence.delete(key: "key")
    #expect(try persistence.load(key: "key") == nil)
}

@Test func settingsRoundTripThroughUserDefaults() throws {
    let name = "io.github.amscotti.iris.tests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let persistence = UserDefaultsPersistence(defaults: suite)
    var settings = AppSettings.defaults
    settings.trailingSpace = false
    settings.providerName = ProviderID.mock.name
    try settings.save(to: persistence)
    #expect(try AppSettings.load(from: persistence) == settings)
}

@Test func keychainErrorsNameOperationAndCode() {
    let error = KeychainError(code: -25300, operation: "load")
    #expect(error.description == "Keychain load failed (-25300).")
    #expect(error == KeychainError(code: -25300, operation: "load"))
    #expect(error != KeychainError(code: -25300, operation: "save"))
}

@Test func bundleIdentifierMatchesTheAppIdentity() throws {
    // The build script writes the bundle ID; logs and the Keychain service
    // use AppIdentity. They must never drift apart.
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(
        contentsOf: packageRoot.appendingPathComponent("Scripts/build_app.sh"), encoding: .utf8)
    let binding = "<key>CFBundleIdentifier</key>\\s*<string>\(AppIdentity.identifier)</string>"
    #expect(script.range(of: binding, options: .regularExpression) != nil)
}

@Test func keychainStoreDefaultsToTheAppIdentity() {
    #expect(KeychainSecretStore().service == AppIdentity.identifier)
}

@Test func secretStoreKeysRejectDegenerateNames() throws {
    #expect(throws: SecretStoreKeys.KeyError.degenerateName) {
        _ = try SecretStoreKeys.key(providerName: "", field: "apiKey")
    }
    #expect(throws: SecretStoreKeys.KeyError.degenerateName) {
        _ = try SecretStoreKeys.key(providerName: " \n", field: "apiKey")
    }
    #expect(throws: SecretStoreKeys.KeyError.degenerateName) {
        _ = try SecretStoreKeys.key(providerName: "Meta", field: " ")
    }
    #expect(throws: SecretStoreKeys.KeyError.degenerateName) {
        _ = try SecretStoreKeys.key(providerName: "Me.ta", field: "apiKey")
    }
    #expect(throws: SecretStoreKeys.KeyError.degenerateName) {
        _ = try SecretStoreKeys.key(providerName: "Meta", field: "api.Key")
    }
    #expect(try SecretStoreKeys.key(providerName: " Meta ") == "iris.apikey.Meta")
}

@Test func damagedNonDataSettingsAreUnreadableNotMissing() throws {
    let name = "io.github.amscotti.iris.tests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    suite.set("not settings data", forKey: AppSettings.storageKey)
    let persistence = UserDefaultsPersistence(defaults: suite)
    let repository = SettingsRepository(persistence: persistence)

    guard case .unavailable = repository.load() else {
        Issue.record("A present-but-not-Data value must read as unreadable, not missing")
        return
    }
    #expect(throws: (any Error).self) { try persistence.load(key: AppSettings.storageKey) }
    #expect(throws: SettingsRepository.RepositoryError.self) { try repository.save(.defaults) }
    #expect(suite.object(forKey: AppSettings.storageKey) as? String == "not settings data")
}

@Test @MainActor func damagedSettingsValueIsPreservableAndRecoverable() throws {
    let name = "io.github.amscotti.iris.tests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    suite.set("not settings data", forKey: AppSettings.storageKey)
    let persistence = UserDefaultsPersistence(defaults: suite)
    let controller = SettingsController(persistence: persistence, registry: ProviderRegistry(), defaults: .defaults)

    #expect(controller.loadIssue != nil)
    #expect(controller.canRecover)
    // Retrying on a still-damaged store fails gracefully: nothing is
    // written and the damaged value is untouched.
    controller.retryLoad()
    #expect(controller.loadIssue != nil)
    #expect(suite.object(forKey: AppSettings.storageKey) as? String == "not settings data")

    // Recovery backs up the serialized damage and returns to writable.
    controller.recover()
    #expect(controller.loadIssue == nil)
    #expect(controller.saveError == nil)
    #expect(!controller.canRecover)
    let preserved = try #require(UserDefaultsPersistence.preservingSerialization(of: "not settings data"))
    try expectRecoveryBackupPlaceholder(persistence, original: preserved)
    #expect(try AppSettings.load(from: persistence) == .defaults)
}
