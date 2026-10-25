import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

@Test func rewriteRouteFollowsTheProvider() {
    let registry = testProviderRegistry()
    #expect(registry.rewriter(for: .meta)?.descriptor.provider == .meta)
    #expect(registry.rewriter(for: .grok)?.descriptor.provider == .grok)
    #expect(registry.rewriter(for: .mock) == nil)
    #expect(registry.rewriter(for: ProviderID("unregistered")) == nil)
}

@Test func grokRewriteRouteUsesGrok46() {
    let descriptor = GrokProvider.rewriteDescriptor
    let adapter = GrokProvider().rewriter as? ChatCompletionsAdapter
    #expect(adapter?.endpoint == "https://api.x.ai/v1/chat/completions")
    #expect(adapter?.instructionRole == "system")
    #expect(descriptor.defaultModel == "grok-4.6")
    #expect(descriptor.modelPresets == ["grok-4.6"])
    #expect(descriptor.defaultEffort == .low)
    #expect(descriptor.effortCases == [.low, .medium, .high, .xhigh])
    #expect(!descriptor.effortCases.contains(.minimal))
    #expect(!descriptor.effortCases.contains(.max))
    #expect(descriptor.coercedEffort(.minimal) == .low)
    #expect(descriptor.coercedEffort(.max) == .xhigh)
    #expect(descriptor.coercedEffort(.low) == .low)
    #expect(descriptor.coercedEffort(.xhigh) == .xhigh)
}

@Test func metaRewriteRouteKeepsMuseDefaults() {
    let descriptor = MetaProvider.rewriteDescriptor
    let adapter = MetaProvider().rewriter as? ChatCompletionsAdapter
    #expect(adapter?.endpoint == "https://api.meta.ai/v1/chat/completions")
    #expect(adapter?.instructionRole == "developer")
    #expect(descriptor.defaultModel == "muse-spark-1.3")
    #expect(descriptor.modelPresets == ["muse-spark-1.3", "muse-wonder-1.0"])
    #expect(descriptor.coercedEffort(.minimal) == .minimal)
    #expect(descriptor.coercedEffort(.max) == .max)
    let config = ProviderConfiguration(
        provider: .meta,
        values: ["apiKey": "fixture-key", "rewriteModel": "muse-wonder-1.0", "rewriteEffort": "max"])
    #expect(RewriteConfiguration(config: config, descriptor: descriptor)?.model == "muse-wonder-1.0")
    #expect(RewriteConfiguration(config: config, descriptor: descriptor)?.effort == .max)
}

@Test func mismatchedRewriteAdapterCannotRouteToAnotherProvider() {
    struct MiswiredProvider: DictationProvider {
        let id = ProviderID("Miswired fixture")
        var descriptor: ConfigDescriptor { ConfigDescriptor(fields: []) }
        var rewriter: (any RewriteAdapter)? { MetaProvider().rewriter }
        func makeClient(config: ProviderConfiguration, transport: any ByteStream) -> any TranscriptionClient {
            MockTranscriptionClient()
        }
    }
    var registry = ProviderRegistry()
    let provider = MiswiredProvider()
    registry.register(provider)
    let config = ProviderConfiguration(provider: provider.id, values: ["apiKey": "fixture-key"])
    #expect(registry.rewriter(for: provider.id) == nil)
    #expect(RewriteConfiguration(config: config, registry: registry) == nil)
}

@Test func rewriteResponseStripsEchoedDictationWrapper() throws {
    let adapter = try #require(GrokProvider().rewriter as? ChatCompletionsAdapter)
    func reply(_ content: String) -> Data {
        Data("{\"choices\":[{\"message\":{\"content\":\(content)}}]}".utf8)
    }
    // A JSON string literal carrying the echoed wrapper.
    let wrapped = "\"<dictation>fish &amp; chips &lt;b&gt;</dictation>\""
    #expect(adapter.responseText(from: reply(wrapped)) == "fish & chips <b>")
    // Unwrapped and partially wrapped replies pass through untouched.
    #expect(adapter.responseText(from: reply("\"plain text\"")) == "plain text")
    #expect(
        adapter.responseText(from: reply("\"say <dictation>hi</dictation> aloud\""))
            == "say <dictation>hi</dictation> aloud")
    // An exactly-empty echoed wrapper is an empty reply, not literal tags.
    #expect(adapter.responseText(from: reply("\"<dictation></dictation>\"")) == nil)
}

@Test func rewriteTokenBudgetGrowsWithEffortAndTranscriptLength() {
    let short = "fix this sentence"
    // Minimal effort on a short take keeps the provider's output floor.
    #expect(ChatCompletionsAdapter.tokenBudget(transcript: short, effort: .minimal, outputFloor: 2_000) == 2_000)
    // Higher effort adds reasoning room instead of starving the reply.
    let low = ChatCompletionsAdapter.tokenBudget(transcript: short, effort: .low, outputFloor: 2_000)
    let high = ChatCompletionsAdapter.tokenBudget(transcript: short, effort: .high, outputFloor: 2_000)
    let max = ChatCompletionsAdapter.tokenBudget(transcript: short, effort: .max, outputFloor: 2_000)
    #expect(2_000 < low && low < high && high < max)
    // A long dictation gets output room at least as long as itself.
    let long = String(repeating: "word ", count: 2_000)
    #expect(ChatCompletionsAdapter.tokenBudget(transcript: long, effort: .minimal, outputFloor: 2_000) >= long.count)
    // Never beyond the adapter's cap.
    let huge = String(repeating: "x", count: 100_000)
    #expect(
        ChatCompletionsAdapter.tokenBudget(transcript: huge, effort: .max, outputFloor: 2_000)
            == ChatCompletionsAdapter.maxTokenBudget)
}
