import Foundation

/// A provider can reuse a standard adapter or supply its own request and
/// response format. No networking or platform frameworks live in the core.
///
/// `nil` meanings: `makeRequest` returns `nil` when the adapter declines
/// this input (rewrite disabled, misconfigured, or filtered) — the caller
/// then inserts the raw transcript. `responseText` returns `nil` when the
/// response body cannot be parsed as a rewrite result (transport errors
/// surface separately through the HTTP executor).
///
/// Request shape: `method` is an uppercased HTTP verb (`"POST"` by
/// default); `url` must be `https` whenever the request carries
/// credentials. Timeout and max-body policy belong to the HTTP executor,
/// not the adapter — adapters only describe the request/response shape.
public protocol RewriteAdapter: Sendable {
    var descriptor: RewriteDescriptor { get }
    func makeRequest(text: String, prompt: PromptDefinition, config: ProviderConfiguration) -> RewriteHTTPRequest?
    func responseText(from data: Data) -> String?
}

public struct RewriteHTTPRequest: Sendable {
    public var url: URL
    /// Uppercase HTTP verb (e.g. `"POST"`).
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String = "POST", headers: [String: String], body: Data) {
        self.url = url
        self.method = method.uppercased()
        self.headers = headers
        self.body = body
    }
}
