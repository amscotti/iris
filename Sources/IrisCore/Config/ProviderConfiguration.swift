import Foundation

/// Provider-agnostic configuration bag.
///
/// Well-known keys are shared with each provider's config descriptor so the
/// settings UI renders fields without naming provider types. Secrets travel
/// here only transiently; at rest they live in the secret store.
public struct ProviderConfiguration: Sendable, Equatable, Hashable {
    public enum Key {
        public static let model = "model"
        public static let mode = "mode"
        public static let audioEncoding = "audioEncoding"
        public static let partialMode = "partialMode"
        public static let languageBias = "languageBias"
        public static let keywords = "keywords"
        public static let apiKey = "apiKey"
        public static let sessionId = "sessionId"
        public static let rewriteModel = "rewriteModel"
        public static let rewriteEffort = "rewriteEffort"
    }

    public var provider: ProviderID
    public var values: [String: String]

    public init(provider: ProviderID, values: [String: String] = [:]) {
        self.provider = provider
        self.values = values
    }

    public func string(_ key: String, default defaultValue: String? = nil) -> String? {
        values[key] ?? defaultValue
    }

    /// Trimmed stored value, falling back when it is absent or blank. Use
    /// for identifiers such as model names, where a blank stored value is
    /// missing data rather than a meaningful wire value.
    public func nonBlankString(_ key: String, default defaultValue: String) -> String {
        let stored = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultValue : stored
    }

    public func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return defaultValue }
        return raw == "true" || raw == "1" || raw == "yes"
    }

    /// Comma-separated list decoding for bias/keyword style fields.
    public func stringList(_ key: String) -> [String] {
        guard let raw = values[key], !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty
        }
    }

    public var apiKey: String? {
        guard let key = values[Key.apiKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Secrets that must never rest in plain persistence, even for a
    /// provider with no registered descriptor. Callers without a
    /// descriptor deny-list these instead of persisting them verbatim.
    public static let wellKnownSecretKeys: Set<String> = [Key.apiKey, Key.sessionId]
}
