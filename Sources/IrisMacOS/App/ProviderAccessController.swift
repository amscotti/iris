import Foundation
import IrisCore
import Observation

/// Owns credential mutations, provider checks, and immutable configuration assembly.
@MainActor
@Observable
public final class ProviderAccessController {
    public let credentials: ProviderCredentials
    public let connections: ProviderConnections
    public private(set) var errors: [String: String] = [:]
    private let registry: ProviderRegistry

    public init(secrets: any SecretStoring, registry: ProviderRegistry, connections: ProviderConnections) {
        credentials = ProviderCredentials(store: secrets)
        self.registry = registry
        self.connections = connections
    }

    public func load(_ name: String, retry: Bool = false) async {
        let required =
            registry.descriptor(forName: name)?.secretKeys
            ?? Set([ProviderConfiguration.Key.apiKey])
        // Read the full persistent set so legacy-migrated secrets the
        // descriptor does not declare (e.g. `sessionId`) resolve after a
        // relaunch; only the descriptor's own secret fields gate readiness.
        let fields =
            required.isEmpty
            ? [] : Array(required.union(ProviderConfiguration.wellKnownSecretKeys)).sorted()
        try? await credentials.load(provider: name, fields: fields, required: required.sorted(), retry: retry)
    }

    func importLegacySecret(_ value: String, field: String, provider: String) async -> Bool {
        let previous = credentials.cachedValues(for: provider)
        do {
            guard try await credentials.importLegacySecret(value, provider: provider, field: field) else {
                return false
            }
            errors[provider] = nil
            if previous != credentials.cachedValues(for: provider) { connections.invalidate(provider) }
            return true
        } catch {
            errors[provider] = "Couldn’t import the saved key. Unlock your Keychain and try again."
            return false
        }
    }

    @discardableResult public func save(_ value: String, field: String, provider: String) async -> Bool {
        let required = registry.descriptor(forName: provider)?.secretKeys ?? [ProviderConfiguration.Key.apiKey]
        credentials.setRequiredFields(required.sorted(), for: provider)
        do {
            try await credentials.save(value, provider: provider, field: field)
            errors[provider] = nil
            connections.invalidate(provider)
            return true
        } catch {
            errors[provider] = "Couldn’t save the key. Unlock your Keychain and try again."
            return false
        }
    }

    @discardableResult public func remove(field: String, provider: String) async -> Bool {
        do {
            try await credentials.remove(provider: provider, field: field)
            errors[provider] = nil
            connections.invalidate(provider)
            return true
        } catch {
            errors[provider] = "Couldn’t remove the key. Unlock your Keychain and try again."
            return false
        }
    }

    public func shouldActivate(_ edited: String, active: String, field: String) -> Bool {
        field == ProviderConfiguration.Key.apiKey && edited != active
            && credentials.state(for: edited) == .saved && credentials.state(for: active) == .missing
    }

    public func hasRequiredSecrets(_ name: String) -> Bool {
        let required = registry.descriptor(forName: name)?.secretKeys ?? [ProviderConfiguration.Key.apiKey]
        let cached = credentials.cachedValues(for: name)
        return required.allSatisfy { !(cached[$0]?.isEmpty ?? true) }
    }

    public func configuration(for name: String, settings: AppSettings) -> ProviderConfiguration {
        let plain = settings.providerConfigs[name] ?? [:]
        var values =
            registry.descriptor(forName: name)?.merged(with: plain)
            ?? plain.filter { !ProviderConfiguration.wellKnownSecretKeys.contains($0.key) }
        values.merge(credentials.cachedValues(for: name)) { _, secret in secret }
        values = registry.provider(for: ProviderID(name))?.normalizeConfiguration(values) ?? values
        return ProviderConfiguration(provider: ProviderID(name), values: values)
    }

    public func check(_ name: String, settings: AppSettings) async {
        await connections.check(configuration(for: name, settings: settings))
    }

    public func settingsChanged(_ providers: Set<String>) {
        for name in providers { connections.invalidate(name) }
    }
}
