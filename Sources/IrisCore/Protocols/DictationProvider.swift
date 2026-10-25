import Foundation

/// The application's provider extension point. A provider owns its settings,
/// presentation, wire client, connection details, and optional rewrite API.
/// The app supplies platform transports and renders these capabilities.
///
/// No-connection path: `connection(for:)` may return `nil` (e.g. missing
/// credentials). `makeClient(config:transport:)` is still non-optional and
/// must then return a client that fails explicitly on use (such as
/// `UnavailableTranscriptionClient`) — never a mock transcript, and never
/// traffic routed through a different provider.
///
/// Key semantics: `normalizeConfiguration` keys are case-sensitive
/// `ProviderConfiguration.Key` strings. Implementations must preserve
/// unknown keys untouched and may only rewrite keys they own; values are
/// stored trimmed. `displayValue(_:for:)` renders a stored value for
/// settings UI and must round-trip (never persist its own output).
public protocol DictationProvider: Sendable {
    var id: ProviderID { get }
    var descriptor: ConfigDescriptor { get }
    var information: ProviderInformation { get }
    var isUserFacing: Bool { get }
    var rewriter: (any RewriteAdapter)? { get }
    func connection(for config: ProviderConfiguration) -> SpeechConnection?
    func makeClient(config: ProviderConfiguration, transport: any ByteStream) -> any TranscriptionClient
    func completionPolicy(for config: ProviderConfiguration) -> TranscriptCompletionPolicy
    func normalizeConfiguration(_ values: [String: String]) -> [String: String]
    func displayValue(_ value: String, for key: String) -> String
}

extension DictationProvider {
    public var information: ProviderInformation {
        ProviderInformation(serviceName: "Speech to text", accountName: id.name)
    }
    public var isUserFacing: Bool { true }
    public var rewriter: (any RewriteAdapter)? { nil }
    public func connection(for config: ProviderConfiguration) -> SpeechConnection? { nil }
    public func completionPolicy(for config: ProviderConfiguration) -> TranscriptCompletionPolicy { .finalEvent }
    public func normalizeConfiguration(_ values: [String: String]) -> [String: String] { values }
    public func displayValue(_ value: String, for key: String) -> String { value }
}

public struct ProviderInformation: Sendable, Equatable, Hashable {
    public var serviceName: String
    public var accountName: String
    /// Where the settings UI points users to issue an API key. Must use
    /// `https` whenever set — key issuance over cleartext is rejected.
    public var apiKeyURL: URL?

    public init(serviceName: String, accountName: String, apiKeyURL: URL? = nil) {
        precondition(
            apiKeyURL?.scheme?.lowercased() == "https" || apiKeyURL == nil, "Provider apiKeyURL must be https.")
        self.serviceName = serviceName
        self.accountName = accountName
        self.apiKeyURL = apiKeyURL
    }
}

public struct SpeechConnection: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}
