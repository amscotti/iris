import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func whitespaceOnlyGrokModelUsesDefaultInConnectionURL() throws {
    let config = ProviderConfiguration(
        provider: .grok, values: ["apiKey": "k", "model": " \t\n "])
    let connection = try #require(GrokProvider().connection(for: config))
    let components = try #require(URLComponents(url: connection.url, resolvingAgainstBaseURL: false))
    let model = components.queryItems?.first { $0.name == "model" }?.value
    #expect(model == GrokSessionConfig.defaultModel)
}
