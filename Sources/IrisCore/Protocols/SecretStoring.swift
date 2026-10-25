import Foundation

/// Keychain-style secret storage. Secrets never live in plain persistence.
///
/// `nil` from `load` means missing. An empty (or whitespace-only) secret
/// is equivalent to missing — `ProviderConfiguration.apiKey` already
/// trims and empties to `nil` — so implementations should treat
/// `save("", forKey:)` as `delete(key:)` and reject empty keys.
/// Keys are non-empty, case-sensitive field identifiers.
public protocol SecretStoring: Sendable {
    func load(key: String) async throws -> String?
    func save(_ value: String, forKey key: String) async throws
    func delete(key: String) async throws
}
