import Foundation

/// Repository-owned version migrations. Value decoding has no provider
/// assembly dependency; callers supply the descriptors that ship in their app.
enum SettingsMigrations {
    private struct LegacyChoice {
        let prompt: PromptDefinition
        let model: String?
        let effort: PromptEffort?
    }

    private static func legacyChoices(for settings: AppSettings, raw: Data) -> [LegacyChoice] {
        let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let stored = object?["prompts"] as? [[String: Any]] ?? []
        var storedByPromptID: [UUID: [String: Any]] = [:]
        for fields in stored {
            guard let rawID = fields["id"] as? String, let id = UUID(uuidString: rawID),
                storedByPromptID[id] == nil
            else { continue }
            storedByPromptID[id] = fields
        }
        return settings.prompts.compactMap { prompt -> LegacyChoice? in
            guard let fields = storedByPromptID[prompt.id] else { return nil }
            let effort = (fields["effort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LegacyChoice(
                prompt: prompt, model: fields["model"] as? String,
                effort: effort.flatMap { $0.isEmpty ? nil : PromptEffort(rawValue: $0) })
        }.sorted {
            if $0.prompt.order != $1.prompt.order { return $0.prompt.order < $1.prompt.order }
            return $0.prompt.id.uuidString < $1.prompt.id.uuidString
        }
    }

    /// Applies known migrations in ascending order and reports whether the
    /// payload still needs a later migration before it can be stamped. The
    /// injectable target makes the next-version boundary testable without
    /// changing the shipped schema constant.
    @discardableResult
    static func apply(
        to settings: inout AppSettings, raw: Data, registry: ProviderRegistry,
        targetVersion: Int = AppSettings.currentSchemaVersion
    ) -> Bool {
        guard settings.schemaVersion < 2 else { return settings.schemaVersion < targetVersion }
        let ordered = legacyChoices(for: settings, raw: raw)
        let descriptors = registry.rewriters.map(\.descriptor)
        // Without descriptors a v1 payload with legacy per-prompt choices
        // cannot be migrated; leave the version unstamped so a later load
        // (with the real registry) can still migrate it. Stamping now would
        // permanently discard those fields on the next save.
        //
        // The same deferral applies when descriptors exist but no choice is
        // attributable: a non-blank legacy model that no descriptor
        // recognizes cannot be seeded anywhere unless the active provider
        // is itself a rewriter. Stamping would discard the choice exactly
        // like the empty-registry case, so wait for a future registry. The
        // deferral is capped by requiring a non-blank model: effort-only
        // leftovers that nobody can claim are stamped away.
        let hasLegacyChoices = ordered.contains { $0.model != nil || $0.effort != nil }
        guard !hasLegacyChoices || !descriptors.isEmpty else { return true }
        let attributable = ordered.contains { choice in
            !(choice.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard
            !attributable
                || Self.legacyChoicesAreClaimable(
                    ordered, descriptors: descriptors, activeProvider: settings.providerName)
        else { return true }
        for descriptor in descriptors {
            let candidates = ordered.filter { choice in
                guard choice.model != nil || choice.effort != nil else { return false }
                let owners = descriptors.filter { $0.recognizesLegacyModel(choice.model) }
                if owners.count == 1 { return owners.first?.provider == descriptor.provider }
                return descriptor.provider.name == settings.providerName
            }
            guard
                let source = candidates.first(where: { $0.prompt.id == settings.selectedPromptID }) ?? candidates.first
            else {
                continue
            }
            let name = descriptor.provider.name
            // Blank or absent legacy choices stay absent. Read time applies
            // today's descriptor default, so a later default change still
            // reaches people who never picked a model or effort.
            if settings.providerConfigs[name]?[ProviderConfiguration.Key.rewriteModel] == nil {
                let model = source.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !model.isEmpty {
                    settings.providerConfigs[name, default: [:]][ProviderConfiguration.Key.rewriteModel] = model
                }
            }
            if settings.providerConfigs[name]?[ProviderConfiguration.Key.rewriteEffort] == nil,
                let effort = source.effort
            {
                settings.providerConfigs[name, default: [:]][ProviderConfiguration.Key.rewriteEffort] =
                    descriptor.coercedEffort(effort).rawValue
            }
        }
        // Mark only the migration actually completed. A future target can
        // then run the next block instead of skipping it or stamping blindly.
        settings.schemaVersion = 2
        return settings.schemaVersion < targetVersion
    }

    /// Whether any legacy choice can be attributed today: exactly one
    /// descriptor recognizes its model, or the active provider is itself a
    /// rewriter that absorbs unclaimed choices.
    private static func legacyChoicesAreClaimable(
        _ ordered: [LegacyChoice], descriptors: [RewriteDescriptor], activeProvider: String
    ) -> Bool {
        let activeIsRewriter = descriptors.contains { $0.provider.name == activeProvider }
        return ordered.contains { choice in
            guard choice.model != nil || choice.effort != nil else { return false }
            let owners = descriptors.filter { $0.recognizesLegacyModel(choice.model) }
            return owners.count == 1 || activeIsRewriter
        }
    }
}
