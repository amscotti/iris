import Foundation

/// An extensible reasoning token. Each provider advertises and validates its
/// own choices, so a provider with a new effort level needs no enum change.
public struct PromptEffort: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let minimal = PromptEffort(rawValue: "minimal")
    public static let low = PromptEffort(rawValue: "low")
    public static let medium = PromptEffort(rawValue: "medium")
    public static let high = PromptEffort(rawValue: "high")
    public static let xhigh = PromptEffort(rawValue: "xhigh")
    public static let max = PromptEffort(rawValue: "max")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
