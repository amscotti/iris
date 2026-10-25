import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

/// A third provider defined entirely in this file. Its rewrite format,
/// authentication header, reasoning tokens, labels, and speech completion
/// policy deliberately differ from the built-in providers.
private struct ThirdProvider: DictationProvider {
    static let identifier = ProviderID("Third fixture")
    let id = identifier
    var rewriter: (any RewriteAdapter)? { ThirdRewriteAdapter() }
    var information: ProviderInformation {
        ProviderInformation(serviceName: "Fixture speech", accountName: "Fixture account")
    }
    var descriptor: ConfigDescriptor {
        ConfigDescriptor(
            fields: [
                ConfigField(key: "apiKey", label: "API key", type: .secret, defaultValue: ""),
                ConfigField(
                    key: "languageBias", label: "Dialect", type: .enum(cases: ["xx"]), defaultValue: "xx",
                    optionLabels: ["xx": "Fixture language"], hint: "Provider-owned guidance."),
            ] + ThirdRewriteAdapter().descriptor.configFields)
    }
    func connection(for config: ProviderConfiguration) -> SpeechConnection? {
        guard let url = URL(string: "wss://third.invalid/listen") else { return nil }
        return SpeechConnection(url: url, headers: ["X-Fixture-Connection": "speech"])
    }
    func normalizeConfiguration(_ values: [String: String]) -> [String: String] {
        values.merging(["normalizedBy": id.name]) { _, value in value }
    }
    func displayValue(_ value: String, for key: String) -> String { value == "alias" ? "xx" : value }
    func completionPolicy(for config: ProviderConfiguration) -> TranscriptCompletionPolicy { .turnComplete }
    func makeClient(config: ProviderConfiguration, transport: any ByteStream) -> any TranscriptionClient {
        ThirdSpeechClient()
    }
}

private struct ThirdSpeechClient: TranscriptionClient {
    private let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        channel.continuation.yield(.speechComplete(turnId: "fixture-turn", transcript: "third provider words"))
        channel.continuation.finish()
    }

    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

private struct ThirdRewriteAdapter: RewriteAdapter {
    let descriptor = RewriteDescriptor(
        provider: ThirdProvider.identifier, defaultModel: "fixture-model-1",
        defaultEffort: PromptEffort(rawValue: "brief"),
        effortCases: [PromptEffort(rawValue: "brief"), PromptEffort(rawValue: "thorough")],
        effortCaption: "Fixture reasoning choices.", legacyModelPrefixes: ["fixture-model-"])

    func makeRequest(text: String, prompt: PromptDefinition, config: ProviderConfiguration) -> RewriteHTTPRequest? {
        guard let settings = RewriteConfiguration(config: config, descriptor: descriptor), let key = config.apiKey,
            let url = URL(string: "https://third.invalid/rewrite"),
            let body = try? JSONSerialization.data(withJSONObject: [
                "input": text, "instructions": prompt.template, "model": settings.model,
                "thinking": settings.effort.rawValue,
            ])
        else { return nil }
        return RewriteHTTPRequest(url: url, headers: ["X-Fixture-Key": key], body: body)
    }

    func responseText(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["output"]
    }
}

private final class ThirdHTTPProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        let correct =
            url.absoluteString == "https://third.invalid/rewrite"
            && request.httpMethod == "POST" && request.value(forHTTPHeaderField: "X-Fixture-Key") == "fixture-key"
        let body = Data((correct ? #"{"output":"extension worked"}"# : #"{"output":"wrong provider request"}"#).utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func thirdProviderRegistersSettingsTransportAndCompletionWithoutAppChanges() async throws {
    var registry = ProviderRegistry()
    registry.register(ThirdProvider())
    let environment = TestEnvironment().make(registry: registry)
    environment.setProvider(ThirdProvider.identifier.name)
    let config = environment.resolvedConfiguration
    #expect(registry.userFacingProviders.contains(ThirdProvider.identifier))
    #expect(config.string("normalizedBy") == ThirdProvider.identifier.name)
    #expect(registry.provider(for: config.provider)?.information.accountName == "Fixture account")
    #expect(
        registry.descriptor(for: config.provider)?.field(for: "languageBias")?.displayName(for: "xx")
            == "Fixture language")
    #expect(registry.provider(for: config.provider)?.displayValue("alias", for: "languageBias") == "xx")
    #expect(RewriteConfiguration(config: config, registry: registry)?.effort.rawValue == "brief")
    #expect(AppComposition.makeTransport(config: config, registry: registry) is URLSessionWebSocketTransport)

    let service = AppComposition.makeServiceFactory(registry: registry)(config)
    try await service.start(config: config)
    await service.finish()
    #expect(await service.lastFinal == "third provider words")
}

@Test func thirdProviderUsesItsOwnRewriteFormatAndReasoningTokens() async throws {
    var registry = ProviderRegistry()
    registry.register(ThirdProvider())
    let config = ProviderConfiguration(
        provider: ThirdProvider.identifier,
        values: ["apiKey": "fixture-key", "rewriteModel": "fixture-model-custom", "rewriteEffort": "thorough"])
    let prompt = PromptDefinition(template: "Shared instructions")
    let adapter = try #require(registry.rewriter(for: config.provider))
    let wire = try #require(adapter.makeRequest(text: "words", prompt: prompt, config: config))
    let body = try #require(try JSONSerialization.jsonObject(with: wire.body) as? [String: String])
    #expect(
        body == [
            "input": "words", "instructions": "Shared instructions", "model": "fixture-model-custom",
            "thinking": "thorough",
        ])
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [ThirdHTTPProtocol.self]
    let session = URLSession(configuration: sessionConfig)
    defer { session.invalidateAndCancel() }
    let client = RewriteChatClient(configuration: config, registry: registry, session: session)
    #expect(await client.rewrite(text: "words", prompt: prompt) == "extension worked")
}

@Test @MainActor func thirdProviderMigrationUsesTheInjectedRegistry() throws {
    var registry = ProviderRegistry()
    registry.register(ThirdProvider())
    let fixture = TestEnvironment()
    let old = Data(
        #"{"providerName":"Third fixture","prompts":[{"id":"88888888-8888-8888-8888-888888888888","template":"Keep this text","model":"fixture-model-legacy","effort":"thorough"}]}"#
            .utf8)
    try fixture.persistence.save(old, forKey: AppSettings.storageKey)
    let environment = fixture.make(registry: registry)
    let rewrite = try #require(RewriteConfiguration(config: environment.resolvedConfiguration, registry: registry))
    #expect(rewrite.model == "fixture-model-legacy")
    #expect(rewrite.effort.rawValue == "thorough")
    #expect(environment.settings.prompts.first?.template == "Keep this text")
}

@Test func providerWithoutRewritesNeverUsesALegacyFallbackRunner() async {
    let prompt = PromptDefinition(template: "Shared instructions")
    let audio = GenerationalAudio()
    let inserter = PressInserter()
    let config = ProviderConfiguration(provider: .mock)
    let loop = DictationOrchestrator(
        audio: audio, inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: AppSettings(prompts: [prompt], selectedPromptID: prompt.id), config: config,
        pressStarter: {
            audio.start()
            return nil
        }, pressEnder: { audio.stop() },
        rewriteRunner: { _, _ in
            Issue.record("Must not fall back to another provider")
            return "wrong"
        },
        rewriteFactory: { config in AppComposition.makeRewrite(config: config, registry: ProviderRegistry()) })
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(inserter.inserts == ["hello world "])
}
