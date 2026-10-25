import Foundation
import IrisCore

/// Single owner of secret-store key derivation. Provider credentials,
/// diagnostics, and tests resolve keys here instead of reaching into
/// `AppEnvironment`.
///
/// Keys are non-empty and case-sensitive: `"Meta"` and `"meta"` address
/// different items. Provider and field names are trimmed of surrounding
/// whitespace; empty or whitespace-only names are rejected here, before
/// they can address a real store item. Names containing `.` are ambiguous
/// with the separator and are rejected the same way.
public enum SecretStoreKeys {
    public enum KeyError: Error, Equatable {
        case degenerateName
    }

    public static func key(
        providerName: String, field: String = ProviderConfiguration.Key.apiKey
    ) throws -> String {
        let provider = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let field = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !field.isEmpty, !provider.contains("."), !field.contains(".")
        else { throw KeyError.degenerateName }
        return field == ProviderConfiguration.Key.apiKey
            ? "iris.apikey.\(provider)" : "iris.secret.\(provider).\(field)"
    }
}
