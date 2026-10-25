import Foundation

/// One typed settings field. The settings UI renders these without naming
/// provider types, so a new provider's options appear automatically.
public struct ConfigField: Sendable, Equatable, Hashable {
    public var key: String
    public var label: String
    public var type: ConfigFieldType
    public var defaultValue: String
    public var advanced: Bool
    public var optionLabels: [String: String]
    public var hint: String?
    public var isVisible: Bool

    public init(
        key: String, label: String, type: ConfigFieldType, defaultValue: String,
        advanced: Bool = false, optionLabels: [String: String] = [:], hint: String? = nil, isVisible: Bool = true
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.advanced = advanced
        self.optionLabels = optionLabels
        self.hint = hint
        self.isVisible = isVisible
    }

    public func displayName(for value: String) -> String { optionLabels[value] ?? value }
}

public enum ConfigFieldType: Sendable, Equatable, Hashable {
    case string
    case secret
    case bool
    case `enum`(cases: [String])
    case enumAllowingCustom(cases: [String])
}

extension ConfigFieldType {
    /// Preset options for picker-style fields, or nil for free-form types.
    public var presetCases: [String]? {
        switch self {
        case .enum(let cases), .enumAllowingCustom(let cases):
            return cases
        case .string, .secret, .bool:
            return nil
        }
    }

    /// Whether the picker offers a free-form entry beyond the presets.
    public var allowsCustom: Bool {
        switch self {
        case .enumAllowingCustom:
            return true
        case .string, .secret, .bool, .enum:
            return false
        }
    }

    /// Picker selection for an effective (emptiness-resolved) value: the
    /// value itself when it matches a preset, otherwise `customTag` so the
    /// UI renders the free-form row with the stored value prefilled.
    public func pickerSelection(for effectiveValue: String, customTag: String) -> String {
        guard allowsCustom, let cases = presetCases else { return effectiveValue }
        return cases.contains(effectiveValue) ? effectiveValue : customTag
    }
}

public struct ConfigDescriptor: Sendable, Equatable, Hashable {
    public var fields: [ConfigField]

    public init(fields: [ConfigField]) {
        self.fields = fields
    }

    public func field(for key: String) -> ConfigField? {
        fields.first { $0.key == key }
    }

    /// Fields shown without interaction. Advanced fields are excluded.
    public var essentialFields: [ConfigField] {
        fields.filter { !$0.advanced && $0.isVisible }
    }

    /// Non-essential fields rendered behind the Advanced disclosure.
    public var advancedFields: [ConfigField] {
        fields.filter { $0.advanced && $0.isVisible }
    }

    /// Provider-agnostic values with each field default applied.
    public func defaultValues() -> [String: String] {
        // Duplicate keys in a hand-written descriptor must not trap at
        // first use; last declaration wins, matching `merged(with:)`.
        Dictionary(fields.map { ($0.key, $0.defaultValue) }, uniquingKeysWith: { _, last in last })
    }

    /// Keys whose values are secrets at rest and must never be persisted
    /// alongside plain settings.
    public var secretKeys: Set<String> {
        Set(fields.filter { $0.type == .secret }.map { $0.key })
    }

    /// Keys whose values are secrets at rest and must never be persisted
    /// alongside plain settings: the descriptor's own secret fields plus the
    /// provider-agnostic well-known secret keys (defense in depth, so a
    /// descriptor that forgets to mark `apiKey` secret still cannot leak it
    /// into plain storage).
    public var persistentSecretKeys: Set<String> {
        secretKeys.union(ProviderConfiguration.wellKnownSecretKeys)
    }

    /// Defaults overlaid with stored plain values. Secrets are excluded:
    /// callers merge them from the secret store separately.
    public func merged(with stored: [String: String]) -> [String: String] {
        var result = defaultValues()
        let secrets = persistentSecretKeys
        for (key, value) in stored where !secrets.contains(key) {
            result[key] = value
        }
        return result
    }

    /// Plain values safe for persistence, with any secret entries removed.
    public func sanitizedForPersistence(_ stored: [String: String]) -> [String: String] {
        let secrets = persistentSecretKeys
        return stored.filter { !secrets.contains($0.key) }
    }
}

/// Registration and capability lookup. Provider policy belongs in the
/// provider modules; the application dispatches through these interfaces.
public struct ProviderRegistry: Sendable {
    public typealias Factory = @Sendable (ProviderConfiguration, any ByteStream) -> any TranscriptionClient

    private var entries: [ProviderID: any DictationProvider]
    private var order: [ProviderID]

    public init() {
        entries = [:]
        order = []
    }

    public mutating func register(
        _ id: ProviderID, descriptor: ConfigDescriptor, factory: @escaping Factory
    ) {
        register(ConfiguredProvider(id: id, descriptor: descriptor, factory: factory))
    }

    public mutating func register(_ provider: any DictationProvider) {
        if entries[provider.id] == nil { order.append(provider.id) }
        entries[provider.id] = provider
    }

    public var availableProviders: [ProviderID] { order }

    /// Providers shown in Settings. Mock stays registered in debug for
    /// tests and the offline demo, but it is not an end-user choice.
    public var userFacingProviders: [ProviderID] {
        availableProviders.filter { entries[$0]?.isUserFacing == true }
    }

    public func provider(for id: ProviderID) -> (any DictationProvider)? { entries[id] }

    public func rewriter(for id: ProviderID) -> (any RewriteAdapter)? {
        guard let adapter = entries[id]?.rewriter, adapter.descriptor.provider == id else { return nil }
        return adapter
    }

    public var rewriters: [any RewriteAdapter] { order.compactMap { rewriter(for: $0) } }

    public func descriptor(for id: ProviderID) -> ConfigDescriptor? {
        entries[id]?.descriptor
    }

    public func descriptor(forName name: String) -> ConfigDescriptor? {
        descriptor(for: ProviderID(name))
    }

    public func makeClient(
        id: ProviderID, config: ProviderConfiguration, transport: any ByteStream
    ) -> (any TranscriptionClient)? {
        guard config.provider == id else { return nil }
        return entries[id]?.makeClient(config: config, transport: transport)
    }

    /// Selection by persisted name. Returns nil for unknown names.
    public func makeClient(
        named name: String, config: ProviderConfiguration, transport: any ByteStream
    ) -> (any TranscriptionClient)? {
        makeClient(id: ProviderID(name), config: config, transport: transport)
    }
}

/// Lightweight registration for tests and providers that need only a client.
private struct ConfiguredProvider: DictationProvider {
    let id: ProviderID
    let descriptor: ConfigDescriptor
    let factory: ProviderRegistry.Factory

    func makeClient(config: ProviderConfiguration, transport: any ByteStream) -> any TranscriptionClient {
        factory(config, transport)
    }
}
