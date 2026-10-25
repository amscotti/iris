import Foundation

/// Identifies a transcription provider by name.
///
/// Providers declare their identifiers in their own modules and register a
/// DictationProvider. There is no central list of identifier cases.
public struct ProviderID: Sendable, Equatable, Hashable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Name used for selection and persistence.
    public var name: String { rawValue }

}
