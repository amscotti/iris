import Foundation

/// Persisted app settings. Secrets are referenced by key, never stored here.
public struct AppSettings: Sendable, Equatable, Hashable, Codable {
    public static let currentSchemaVersion = 2
    /// Persisted legacy fallback, independent of the concrete provider module.
    /// New application defaults are supplied by composition through the repository.
    public static let legacyProviderName = "Meta"

    public enum InsertMethod: String, Sendable, Equatable, Hashable, Codable {
        case keystroke
        case paste
    }

    public var schemaVersion: Int
    public var providerName: String
    /// Plain (non-secret) values namespaced per provider, so each provider
    /// keeps its own configuration and switching providers never wipes the
    /// other provider's options. Secrets stay in the secret store.
    public var providerConfigs: [String: [String: String]]
    /// Plain values for the active provider. Reads and writes that
    /// provider's namespace inside `providerConfigs`.
    public var providerValues: [String: String] {
        get { providerConfigs[providerName] ?? [:] }
        set { providerConfigs[providerName] = newValue }
    }
    public var hotkey: HotkeyConfiguration
    public var insertMethod: InsertMethod
    public var trailingSpace: Bool
    public var trailingNewline: Bool
    public var reduceMotion: Bool
    /// When true, the pill plate is a HUD glass so the desktop shows through.
    /// The waveform itself stays opaque. System Reduce Transparency forces
    /// the solid plate on.
    public var pillTranslucent: Bool
    /// RRGGBB tint for the pill waveform, or nil for the built-in blue.
    public var waveformColorHex: String?
    /// User-defined rewrite prompts, in sidebar order. Empty by default;
    /// nothing is merged in at load, so stored settings stay exactly as
    /// the user left them.
    public var prompts: [PromptDefinition]
    /// The single active rewrite prompt, or nil for None. None is the
    /// default zero-LLM bypass: prompts never combine.
    public var selectedPromptID: UUID?

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        providerName: String = AppSettings.legacyProviderName,
        providerValues: [String: String] = [:],
        providerConfigs: [String: [String: String]]? = nil,
        hotkey: HotkeyConfiguration = HotkeyConfiguration(),
        insertMethod: InsertMethod = .keystroke,
        trailingSpace: Bool = true,
        trailingNewline: Bool = false,
        reduceMotion: Bool = false,
        pillTranslucent: Bool = true,
        waveformColorHex: String? = nil,
        prompts: [PromptDefinition] = [],
        selectedPromptID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.providerName = providerName
        if let providerConfigs {
            self.providerConfigs = providerConfigs
        } else {
            self.providerConfigs = providerValues.isEmpty ? [:] : [providerName: providerValues]
        }
        self.hotkey = hotkey
        self.insertMethod = insertMethod
        self.trailingSpace = trailingSpace
        self.trailingNewline = trailingNewline
        self.reduceMotion = reduceMotion
        self.pillTranslucent = pillTranslucent
        self.waveformColorHex = waveformColorHex
        self.prompts = prompts
        self.selectedPromptID = selectedPromptID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case providerName
        case providerConfigs
        case legacyProviderValues = "providerValues"
        case hotkey
        case insertMethod
        case trailingSpace
        case trailingNewline
        case reduceMotion
        case pillTranslucent
        case waveformColorHex
        case prompts
        case selectedPromptID
    }

    /// Tolerant decoding: payloads written before a field existed load
    /// with that field's default instead of failing. Payloads written
    /// before selection replaced the per-prompt toggles migrate the first
    /// enabled prompt in sidebar order into the selection.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName) ?? Self.legacyProviderName
        if let configs = try container.decodeIfPresent(
            [String: [String: String]].self, forKey: .providerConfigs)
        {
            providerConfigs = configs
        } else {
            // Payloads written before per-provider namespaces kept one flat
            // map for the active provider; adopt it as that provider's own.
            let legacy =
                try container.decodeIfPresent([String: String].self, forKey: .legacyProviderValues) ?? [:]
            providerConfigs = legacy.isEmpty ? [:] : [providerName: legacy]
        }
        // Type damage in the hotkey payload is corruption, not a default:
        // the bare try propagates it so the payload is preserved for
        // recovery instead of silently resetting the whole struct.
        hotkey = try container.decodeIfPresent(HotkeyConfiguration.self, forKey: .hotkey) ?? HotkeyConfiguration()
        // Unknown future insert-method VALUES fall back to keystroke so one
        // new value cannot discard prompts and provider configuration; a
        // genuine type mismatch still throws like the siblings above.
        let rawMethod = try container.decodeIfPresent(String.self, forKey: .insertMethod)
        insertMethod = rawMethod.flatMap { InsertMethod(rawValue: $0) } ?? .keystroke
        trailingSpace = try container.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? true
        trailingNewline = try container.decodeIfPresent(Bool.self, forKey: .trailingNewline) ?? false
        reduceMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        pillTranslucent = try container.decodeIfPresent(Bool.self, forKey: .pillTranslucent) ?? true
        waveformColorHex = WaveformTint.normalize(
            try container.decodeIfPresent(String.self, forKey: .waveformColorHex))
        let stored = try container.decodeIfPresent([StoredPrompt].self, forKey: .prompts) ?? []
        prompts = stored.map { $0.definition }
        let savedSelection = try container.decodeIfPresent(UUID.self, forKey: .selectedPromptID) ?? nil
        if let savedSelection, stored.contains(where: { $0.id == savedSelection }) {
            selectedPromptID = savedSelection
        } else {
            selectedPromptID =
                stored.sorted(by: StoredPrompt.sidebarOrder)
                .first(where: { $0.enabled ?? false })?.id
        }
    }

    /// Encodes namespaced configs only. The legacy flat `providerValues` key is decode-only.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(providerName, forKey: .providerName)
        try container.encode(providerConfigs, forKey: .providerConfigs)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(insertMethod, forKey: .insertMethod)
        try container.encode(trailingSpace, forKey: .trailingSpace)
        try container.encode(trailingNewline, forKey: .trailingNewline)
        try container.encode(reduceMotion, forKey: .reduceMotion)
        try container.encode(pillTranslucent, forKey: .pillTranslucent)
        try container.encodeIfPresent(waveformColorHex, forKey: .waveformColorHex)
        try container.encode(prompts, forKey: .prompts)
        try container.encodeIfPresent(selectedPromptID, forKey: .selectedPromptID)
    }

    public static var defaults: AppSettings { AppSettings() }

    public static let storageKey = "iris.appSettings"

    public var waveformTint: WaveformTint { WaveformTint(hex: waveformColorHex) }

    /// The active rewrite prompt, or nil when None is selected or the
    /// stored id names no prompt.
    public var selectedPrompt: PromptDefinition? {
        guard let selectedPromptID else { return nil }
        return prompts.first { $0.id == selectedPromptID }
    }

    public var providerConfiguration: ProviderConfiguration {
        // Strip well-known secrets so a legacy payload with `apiKey` staged
        // in `providerConfigs` never flows to a client as a plain value.
        // Callers with a registry should prefer `providerConfiguration(using:)`,
        // which also strips descriptor-declared secret fields.
        var values = providerValues
        for key in ProviderConfiguration.wellKnownSecretKeys { values.removeValue(forKey: key) }
        return ProviderConfiguration(provider: ProviderID(providerName), values: values)
    }

    /// Registry-aware variant: strips every secret field the provider's
    /// descriptor declares (falling back to the well-known secret keys when
    /// the provider is unregistered), without applying defaults.
    public func providerConfiguration(using registry: ProviderRegistry) -> ProviderConfiguration {
        let plain = providerValues
        if let descriptor = registry.descriptor(forName: providerName) {
            return ProviderConfiguration(
                provider: ProviderID(providerName),
                values: descriptor.sanitizedForPersistence(plain))
        }
        var values = plain
        for key in ProviderConfiguration.wellKnownSecretKeys { values.removeValue(forKey: key) }
        return ProviderConfiguration(provider: ProviderID(providerName), values: values)
    }

    /// Test-only convenience (internal, for `@testable` tests and the
    /// repository). App code saves through `SettingsRepository.save(_:)`,
    /// which latches writes off while stored settings are unreadable so a
    /// corrupt payload is never overwritten without a backed-up recovery.
    func save(to persistence: any PersistenceProviding) throws {
        try persistence.save(self, forKey: Self.storageKey)
    }

    /// Test-only convenience that collapses every unreadable outcome into one
    /// error; app code uses `SettingsRepository.load()` for recovery details.
    static func load(
        from persistence: any PersistenceProviding, registry: ProviderRegistry = ProviderRegistry()
    ) throws -> AppSettings {
        switch SettingsRepository(persistence: persistence, registry: registry).load() {
        case .missing(let settings), .loaded(let settings): return settings
        case .unsupportedVersion, .corrupt, .unavailable: throw SettingsRepository.RepositoryError.recoveryRequired
        }
    }
}

/// Decoding shape for one stored prompt. Tolerates payloads written before
/// a field existed (defaults apply) and payloads from before selection
/// replaced the per-prompt `enabled` toggle.
private struct StoredPrompt: Decodable {
    var id: UUID
    var name: String
    var template: String
    var order: Int
    var enabled: Bool?

    var definition: PromptDefinition {
        PromptDefinition(id: id, name: name, template: template, order: order)
    }

    static func sidebarOrder(_ lhs: StoredPrompt, _ rhs: StoredPrompt) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case template
        case order
        case enabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A prompt without an id is damage, not a fresh prompt: regenerating
        // a random UUID per decode would silently orphan the saved selection
        // and make edit/delete target the wrong record. Treat it as corrupt
        // so the payload is preserved for recovery instead.
        guard let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.id, in: container,
                debugDescription: "Stored prompt is missing its id.")
        }
        id = decodedID
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}
