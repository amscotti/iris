import Foundation
import IrisCore

/// The only place that constructs the live system adapters and application
/// graph. Tests construct the same graph using explicit in-memory ports.
@MainActor
public enum AppComposition {
    public static func liveEnvironment() -> AppEnvironment {
        let registry = AppProviderAssembly.defaultRegistry()
        let makeService = makeServiceFactory(registry: registry)
        let clipboard = LiveClipboard()
        let focus = LiveFocus()
        let ports = DictationRuntimePorts(
            audio: AVAudioEngineCapturer(),
            inserter: AccessControlTextInserter(clipboard: clipboard, focus: focus, keys: LiveKeyPosting()),
            hotkey: GlobalHotkeyMonitor(), focus: focus,
            authorization: CaptureAuthorization(
                microphone: LivePermissionProbes.microphone,
                accessibility: LivePermissionProbes.accessibility,
                image: LivePermissionProbes.image),
            systemEvents: SystemEvents(), makeService: makeService,
            rewriteFactory: { config in makeRewrite(config: config, registry: registry) })
        return AppEnvironment(
            persistence: UserDefaultsPersistence(), secrets: KeychainSecretStore(), registry: registry,
            permissions: PermissionsManager(), runtimePorts: ports,
            connections: ProviderConnections(
                probe: { config in
                    try await SpeechConnectionProbe.check(config, makeService: makeService)
                },
                requiresAPIKey: { config in
                    // Keyless providers (no secret fields in their
                    // descriptor) must remain testable without an API key.
                    if let descriptor = registry.descriptor(forName: config.provider.name) {
                        return descriptor.secretKeys.contains(ProviderConfiguration.Key.apiKey)
                    }
                    return true
                }), clipboard: clipboard, defaults: AppProviderAssembly.defaultSettings)
    }
}
