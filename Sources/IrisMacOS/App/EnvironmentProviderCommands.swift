import Foundation
import IrisCore

/// Presentation commands delegate policy, storage, and configuration to controllers.
@MainActor
extension AppEnvironment {
    /// Switches the active provider. Every provider keeps its own plain
    /// values and secret, so switching never wipes the other provider's
    /// configuration. A first visit opens an empty namespace: defaults are
    /// supplied at read time (`ConfigDescriptor.merged(with:)`), so a future
    /// build that changes a descriptor default still reaches existing users
    /// instead of losing to values frozen as if the user chose them. Prompt
    /// text is a shared library.
    public func setProvider(_ name: String) {
        settingsController.setProvider(name)
    }

    /// Updates one plain (non-secret) provider value and rebinds the client.
    /// Secret fields must go through `saveSecret` so they never touch
    /// plain persistence.
    public func setProviderValue(key: String, value: String, provider: String? = nil) {
        settingsController.setProviderValue(key: key, value: value, provider: provider ?? settings.providerName)
    }

    public func loadSecret(field key: String, provider: String? = nil) async -> String? {
        let name = provider ?? settings.providerName
        await loadProviderCredentials(name)
        return credentials.cachedValues(for: name)[key]
    }

    public func hasSecret(field key: String, provider: String? = nil) async -> Bool {
        guard let value = await loadSecret(field: key, provider: provider) else { return false }
        return !value.isEmpty
    }

    @discardableResult
    public func saveSecret(_ value: String, field key: String, provider: String? = nil) async -> Bool {
        await beginPermissionChange()
        defer { endPermissionChange() }
        let name = provider ?? settings.providerName
        guard await providerAccess.save(value, field: key, provider: name) else { return false }
        clearRetainedNotice()
        applyRestingStatus()
        scrubSupersededPlaintextSecret(field: key, provider: name)
        if providerAccess.shouldActivate(name, active: settings.providerName, field: key) { setProvider(name) }
        await resolveConfiguration()
        await checkStartupGate(openSettingsWhenBlocked: false)
        return true
    }

    @discardableResult
    public func clearSecret(field key: String, provider: String? = nil) async -> Bool {
        await beginPermissionChange()
        defer { endPermissionChange() }
        let name = provider ?? settings.providerName
        guard await providerAccess.remove(field: key, provider: name) else { return false }
        scrubSupersededPlaintextSecret(field: key, provider: name)
        await resolveConfiguration()
        await checkStartupGate(openSettingsWhenBlocked: false)
        return true
    }

    private func scrubSupersededPlaintextSecret(field key: String, provider name: String) {
        let confirmed = [name: Set([key])]
        settingsController.confirmImportedSecrets(confirmed)
        guard let scrubbed = settingsController.settingsByRemovingSecrets(confirmed) else { return }
        suppressStartupGateRecheck = true
        settingsController.save(scrubbed)
        suppressStartupGateRecheck = false
    }

    public var canRecoverSettings: Bool { settingsController.canRecover }
    public func retrySettingsLoad() { settingsController.retryLoad() }
    public func recoverSettings() { settingsController.recover() }

    /// Copies legacy plaintext secrets into the Keychain,
    /// then removes them from preferences. A Keychain read or write failure
    /// leaves that field's plaintext in place: it may be the only copy.
    /// Fields imported before the failure are still scrubbed. An existing
    /// non-empty Keychain value is kept. The scrubbing save does not schedule
    /// a startup-gate check; the launch or retry caller owns that check.
    func importPlaintextSecrets(retry: Bool = false) async {
        let pending = settingsController.plaintextSecrets()
        guard !pending.isEmpty else { return }
        let imported = await importPendingSecrets(pending, retry: retry)
        settingsController.confirmImportedSecrets(imported)
        guard let scrubbed = settingsController.settingsByRemovingSecrets(imported) else { return }
        suppressStartupGateRecheck = true
        settingsController.save(scrubbed)
        suppressStartupGateRecheck = false
    }

    private func importPendingSecrets(
        _ pending: [String: [String: String]], retry: Bool
    ) async -> [String: Set<String>] {
        var imported: [String: Set<String>] = [:]
        for (provider, fields) in pending.sorted(by: { $0.key < $1.key }) {
            // A provider whose name cannot address a secret-store item can
            // never import; skip it instead of aborting every other
            // provider's migration.
            guard (try? SecretStoreKeys.key(providerName: provider)) != nil else { continue }
            await providerAccess.load(provider, retry: retry)
            if case .unavailable = credentials.state(for: provider) { continue }
            for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
                // One provider's Keychain failure leaves that provider's
                // plaintext in place (it may be the only copy) without
                // blocking the rest of the chain.
                guard await providerAccess.importLegacySecret(value, field: field, provider: provider) else {
                    continue
                }
                imported[provider, default: []].insert(field)
            }
        }
        return imported
    }
    func resolveConfiguration() async {
        await loadProviderCredentials(settings.providerName)
        publishConfiguration()
    }

    public func loadProviderCredentials(_ name: String, retry: Bool = false) async {
        let mayPrompt = runtime.isStarted && (credentials.state(for: name) == .notLoaded || retry)
        if mayPrompt { await beginPermissionChange() }
        defer { if mayPrompt { endPermissionChange() } }
        await providerAccess.load(name, retry: retry)
        if retry {
            switch credentials.state(for: name) {
            case .unavailable: break
            default: await importPlaintextSecrets(retry: true)
            }
        }
        publishConfiguration()
    }

    public func testProviderConnection(_ name: String) async {
        await loadProviderCredentials(name)
        await providerAccess.check(name, settings: settings)
        if connections.state(for: name) == .connected {
            clearRetainedNotice()
            applyRestingStatus()
        }
    }

    func configuration(for name: String) -> ProviderConfiguration {
        providerAccess.configuration(for: name, settings: settings)
    }
    var resolvedConfiguration: ProviderConfiguration { runtime.configuration }
    func publishConfiguration() {
        runtime.update(settings: settings, config: configuration(for: settings.providerName))
    }
}
