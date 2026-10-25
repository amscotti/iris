import Foundation

/// Provider-supplied rewrite capabilities. Defaults, choices, aliases, and
/// legacy model matching are data, so adding a provider needs no new switch.
public struct RewriteDescriptor: Sendable, Equatable, Hashable {
    public let provider: ProviderID
    public let defaultModel: String
    public let modelPresets: [String]
    public let defaultEffort: PromptEffort
    public let effortCases: [PromptEffort]
    public let effortCaption: String
    private let effortAliases: [PromptEffort: PromptEffort]
    private let legacyModelPrefixes: [String]

    public init(
        provider: ProviderID, defaultModel: String, modelPresets: [String]? = nil,
        defaultEffort: PromptEffort, effortCases: [PromptEffort], effortCaption: String,
        effortAliases: [PromptEffort: PromptEffort] = [:], legacyModelPrefixes: [String] = []
    ) {
        self.provider = provider
        self.defaultModel = defaultModel
        self.modelPresets = modelPresets ?? [defaultModel]
        self.defaultEffort = defaultEffort
        self.effortCases = effortCases
        self.effortCaption = effortCaption
        self.effortAliases = effortAliases
        self.legacyModelPrefixes = legacyModelPrefixes
    }

    public func coercedEffort(_ effort: PromptEffort) -> PromptEffort {
        if effortCases.contains(effort) { return effort }
        if let mapped = effortAliases[effort], effortCases.contains(mapped) { return mapped }
        return defaultEffort
    }

    public var configFields: [ConfigField] {
        [
            ConfigField(
                key: ProviderConfiguration.Key.rewriteModel, label: "Rewrite model",
                type: .enumAllowingCustom(cases: modelPresets), defaultValue: defaultModel, advanced: true),
            ConfigField(
                key: ProviderConfiguration.Key.rewriteEffort, label: "Reasoning",
                type: .enum(cases: effortCases.map(\.rawValue)), defaultValue: defaultEffort.rawValue, advanced: true),
        ]
    }

    /// Migration only. Runtime routing never follows a model name.
    func recognizesLegacyModel(_ model: String?) -> Bool {
        let name = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return legacyModelPrefixes.contains { name.hasPrefix($0.lowercased()) }
    }
}

/// Immutable model/effort settings resolved from one provider's config.
/// This snapshot travels with that provider's key for the whole take.
public struct RewriteConfiguration: Sendable, Equatable, Hashable {
    public static let settingKeys: Set<String> = [
        ProviderConfiguration.Key.rewriteModel, ProviderConfiguration.Key.rewriteEffort,
    ]

    public let provider: ProviderID
    public let model: String
    public let effort: PromptEffort

    public init?(config: ProviderConfiguration, registry: ProviderRegistry) {
        guard let rewriter = registry.rewriter(for: config.provider) else { return nil }
        self.init(config: config, descriptor: rewriter.descriptor)
    }

    public init?(config: ProviderConfiguration, descriptor: RewriteDescriptor) {
        guard config.provider == descriptor.provider else { return nil }
        self.provider = config.provider
        let model =
            config.string(ProviderConfiguration.Key.rewriteModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = model.isEmpty ? descriptor.defaultModel : model
        let rawEffort =
            config.string(ProviderConfiguration.Key.rewriteEffort)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Trimmed like rewriteModel above; matching stays case-sensitive and
        // unknown values fall back via coercedEffort.
        let effort = rawEffort.isEmpty ? nil : PromptEffort(rawValue: rawEffort)
        self.effort = descriptor.coercedEffort(effort ?? descriptor.defaultEffort)
    }
}
