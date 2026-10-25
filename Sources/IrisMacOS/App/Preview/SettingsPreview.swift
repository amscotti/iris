#if DEBUG
    import AppKit
    import Foundation
    import IrisCore
    import IrisProviders

    /// Developer-only UI preview: no live keys, requests, capture, or hotkey tap.
    /// Launch with --preview-settings to inspect the actual accessory window.
    @MainActor
    enum SettingsPreview {
        static func makeEnvironment() -> AppEnvironment {
            let persistence = PreviewSettingsStore()
            var settings = AppProviderAssembly.defaultSettings
            settings.prompts = [AppEnvironment.examplePrompt(order: 0)]
            try? SettingsRepository(persistence: persistence).save(settings)
            return AppEnvironment(
                persistence: persistence,
                secrets: PreviewSecretStore(),
                registry: AppProviderAssembly.defaultRegistry(),
                permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
                runtimePorts: PreviewRuntime.ports(),
                connections: ProviderConnections(probe: { config in
                    if config.apiKey == "invalid" { throw TranscriptionError.auth("Preview: rejected key") }
                }), clipboard: PreviewClipboard(), defaults: AppProviderAssembly.defaultSettings,
                isSettingsPreview: true)
        }
    }

    private final class PreviewSettingsStore: PersistenceProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func load(key: String) throws -> Data? { lock.withLock { values[key] } }
        func save(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
        func delete(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    }

    private actor PreviewSecretStore: SecretStoring {
        private var values = ["iris.apikey.Meta": "preview-only"]
        func load(key: String) async throws -> String? { values[key] }
        func save(_ value: String, forKey key: String) async throws { values[key] = value }
        func delete(key: String) async throws { values.removeValue(forKey: key) }
    }
#endif
