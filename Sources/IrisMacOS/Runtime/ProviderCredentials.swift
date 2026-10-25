import Foundation
import IrisCore
import Observation

public enum ProviderKeyState: Equatable, Sendable {
    case notLoaded
    case loading
    case missing
    case saved
    case unavailable(String)
}

/// Reads a provider's secrets once per app session. Settings edits use the
/// cache, not repeated Keychain reads. Revisions prevent a delayed load from
/// restoring a key that the person has just replaced or removed.
@MainActor
@Observable
public final class ProviderCredentials {
    public private(set) var states: [String: ProviderKeyState] = [:]
    private let store: any SecretStoring
    @ObservationIgnored private var values: [String: [String: String]] = [:]
    @ObservationIgnored private var loadedFields: [String: Set<String>] = [:]
    private struct InFlightLoad {
        let id = UUID()
        let fields: Set<String>
        let task: Task<[String: String], Error>
    }

    @ObservationIgnored private var loads: [String: InFlightLoad] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    /// Secret fields required for `.saved` readiness per provider, captured
    /// from the last `load(provider:fields:)` call. Defaults to `[apiKey]`
    /// for providers never loaded (e.g. after a direct `save`/`remove`).
    @ObservationIgnored private var requiredFields: [String: [String]] = [:]

    public init(store: any SecretStoring) {
        self.store = store
    }

    public func state(for provider: String) -> ProviderKeyState {
        states[provider] ?? .notLoaded
    }

    func cachedValues(for provider: String) -> [String: String] {
        values[provider] ?? [:]
    }

    /// Seed descriptor readiness before the first load or save. Without this,
    /// the apiKey-only fallback can mark a multi-secret provider saved early.
    func setRequiredFields(_ fields: [String], for provider: String) {
        requiredFields[provider] = fields
    }

    /// `fields` are read from the store; `required` gates `.saved`
    /// readiness (defaults to `fields`). They differ when the read set is
    /// wider than the descriptor's own secret fields, e.g. to resolve a
    /// legacy-migrated `sessionId` that readiness must not depend on.
    func load(provider: String, fields: [String], required: [String]? = nil, retry: Bool = false) async throws {
        requiredFields[provider] = required ?? fields
        // A cancelled/locked Keychain read is a settled state, not a reason
        // to prompt again on every activation or settings edit. Retry is an
        // explicit action in the provider editor.
        if case .unavailable = state(for: provider), !retry { return }
        while true {
            let cachedFields = loadedFields[provider] ?? []
            let missingFields = fields.filter { !cachedFields.contains($0) }
            if missingFields.isEmpty {
                values[provider] = values[provider] ?? [:]
                updateState(provider: provider)
                return
            }
            let revision = revisions[provider, default: 0]
            let inFlight = loads[provider] ?? startLoadTask(provider: provider, fields: missingFields)
            do {
                let loaded = try await inFlight.task.value
                guard revisions[provider, default: 0] == revision else { return }
                var merged = values[provider] ?? [:]
                for (field, value) in loaded { merged[field] = value }
                values[provider] = merged
                loadedFields[provider, default: []].formUnion(inFlight.fields)
                if loads[provider]?.id == inFlight.id { loads[provider] = nil }
                updateState(provider: provider)
            } catch {
                guard revisions[provider, default: 0] == revision else { return }
                if loads[provider]?.id == inFlight.id { loads[provider] = nil }
                states[provider] = .unavailable("Couldn’t read the API key. Unlock your Keychain and try again.")
                throw error
            }
        }
    }

    private func startLoadTask(provider: String, fields: [String]) -> InFlightLoad {
        states[provider] = .loading
        let task = Task { [store] in
            var loaded: [String: String] = [:]
            for field in fields {
                let key = try SecretStoreKeys.key(providerName: provider, field: field)
                if let value = try await store.load(key: key) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { loaded[field] = trimmed }
                }
            }
            return loaded
        }
        let inFlight = InFlightLoad(fields: Set(fields), task: task)
        loads[provider] = inFlight
        return inFlight
    }

    /// Uncached migration fields are read directly, including secrets outside
    /// the descriptor's required fields. A newer edit wins over a suspended read.
    func importLegacySecret(_ value: String, provider: String, field: String) async throws -> Bool {
        if let cached = values[provider]?[field], !cached.isEmpty { return true }
        let revision = revisions[provider, default: 0]
        do {
            let stored = try await store.load(key: SecretStoreKeys.key(providerName: provider, field: field))
            guard revisions[provider, default: 0] == revision else { return false }
            if let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
                cache(stored, provider: provider, field: field)
            } else {
                try await save(value, provider: provider, field: field)
            }
            return true
        } catch {
            let required = requiredFields[provider] ?? [ProviderConfiguration.Key.apiKey]
            if required.contains(field), state(for: provider) == .missing {
                states[provider] = .unavailable("Couldn’t import the saved key. Unlock your Keychain and try again.")
            }
            throw error
        }
    }

    func save(_ value: String, provider: String, field: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try await remove(provider: provider, field: field)
            return
        }
        try await store.save(trimmed, forKey: SecretStoreKeys.key(providerName: provider, field: field))
        cache(trimmed, provider: provider, field: field)
    }

    func remove(provider: String, field: String) async throws {
        try await store.delete(key: SecretStoreKeys.key(providerName: provider, field: field))
        invalidateLoad(provider: provider)
        values[provider]?.removeValue(forKey: field)
        loadedFields[provider, default: []].insert(field)
        updateState(provider: provider)
    }

    private func cache(_ value: String, provider: String, field: String) {
        invalidateLoad(provider: provider)
        values[provider, default: [:]][field] = value
        loadedFields[provider, default: []].insert(field)
        updateState(provider: provider)
    }

    private func invalidateLoad(provider: String) {
        revisions[provider, default: 0] += 1
        loads.removeValue(forKey: provider)?.task.cancel()
    }

    private func updateState(provider: String) {
        let required = requiredFields[provider] ?? [ProviderConfiguration.Key.apiKey]
        let stored = values[provider] ?? [:]
        // A provider whose descriptor declares no secret fields is ready as
        // soon as it exists: an empty `required` must mean "no key needed",
        // not "permanently missing".
        let ready =
            required.allSatisfy { !(stored[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        states[provider] = ready ? .saved : .missing
    }
}
