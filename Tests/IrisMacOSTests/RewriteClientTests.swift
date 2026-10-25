import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

/// URLProtocol stub controlling status, body, and latency per test.
final class StubChatProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body: Data?
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    nonisolated(unsafe) private static var captured: URLRequest?

    static func stub(status: Int, body: Data?, delay: TimeInterval = 0) {
        lock.lock()
        self.status = status
        self.body = body
        self.delay = delay
        captured = nil
        lock.unlock()
    }

    static var capturedRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private struct Snapshot {
        var status: Int
        var body: Data?
        var delay: TimeInterval
    }

    private static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(status: status, body: body, delay: delay)
    }

    private static func capture(_ request: URLRequest) {
        lock.lock()
        captured = request
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var delayTimer: Timer?

    override func startLoading() {
        Self.capture(request)
        let delay = Self.snapshot().delay
        guard delay > 0 else { return respond() }
        // Delay on the loading thread's run loop instead of sleeping on it:
        // a blocked thread would also stall every other stubbed request.
        let timer = Timer(
            timeInterval: delay, target: self, selector: #selector(respond), userInfo: nil, repeats: false)
        delayTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    @objc private func respond() {
        let snapshot = Self.snapshot()
        let (status, body) = (snapshot.status, snapshot.body)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        delayTimer?.invalidate()
    }
}

@Suite(.serialized)
struct RewriteClientSuite {
    private func chatSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubChatProtocol.self]
        return URLSession(configuration: config)
    }

    private func chatClient(
        key: String? = "test-key", timeout: TimeInterval = 5,
        provider: ProviderID = .meta, model: String? = nil, effort: PromptEffort? = nil,
        deadline: TimeInterval? = nil
    ) -> RewriteChatClient {
        var values: [String: String] = [:]
        values["apiKey"] = key
        values["rewriteModel"] = model
        values["rewriteEffort"] = effort?.rawValue
        return RewriteChatClient(
            configuration: ProviderConfiguration(provider: provider, values: values),
            registry: AppProviderAssembly.defaultRegistry(),
            session: chatSession(), timeoutSeconds: timeout,
            deadlineSeconds: deadline ?? RewriteChatClient.deadlineSeconds)
    }

    private func chatJSON(_ text: String) -> Data { Data(text.utf8) }

    /// URLSession may move the body into a stream before the protocol sees
    /// it, so read either form.
    private func sentBody() -> Data? {
        guard let request = StubChatProtocol.capturedRequest else { return nil }
        if let direct = request.httpBody { return direct }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func requestBody() throws -> [String: Any] {
        let request = try #require(StubChatProtocol.capturedRequest)
        #expect(request.url?.absoluteString == "https://api.meta.ai/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let raw = try #require(sentBody())
        let decoded = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return decoded
    }

    @Test func chatSuccessReturnsTrimmedReply() async throws {
        StubChatProtocol.stub(
            status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"  cleaned text  "}}]}"#))
        let client = chatClient()
        let prompt = PromptDefinition(name: "Cleanup", template: "Fix {{transcript}}", order: 0)
        #expect(await client.rewrite(text: "raw words", prompt: prompt) == "cleaned text")
        let body = try requestBody()
        #expect(body["model"] as? String == "muse-spark-1.3")
        #expect(body["max_tokens"] as? Int == 2_000)
        #expect(body["reasoning_effort"] as? String == "minimal")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "developer")
        #expect(messages[0]["content"] == "Fix <dictation>raw words</dictation>")
        #expect(messages[1] == ["role": "user", "content": "<dictation>raw words</dictation>"])
    }

    @Test(arguments: ["grok-4.6", "", " \n"])
    func grokRoutePostsToXAIWithSystemRoleAndMappedEffort(model: String) async throws {
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"ok"}}]}"#))
        let client = chatClient(provider: .grok, model: model, effort: .minimal)
        let prompt = PromptDefinition(
            name: "Cleanup", template: "Fix {{transcript}}", order: 0)
        #expect(await client.rewrite(text: "raw words", prompt: prompt) == "ok")
        let request = try #require(StubChatProtocol.capturedRequest)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let raw = try #require(sentBody())
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(body["model"] as? String == "grok-4.6")
        #expect(body["reasoning_effort"] as? String == "low")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["role"] == "system")
    }

    @Test func chatRequestCarriesModelEffortAndEscaping() async throws {
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"ok"}}]}"#))
        let client = chatClient(model: "custom-9", effort: .max)
        let prompt = PromptDefinition(name: "Formal", template: "Formalize", order: 0)
        #expect(await client.rewrite(text: "a & <b>", prompt: prompt) == "ok")
        let body = try requestBody()
        #expect(body["model"] as? String == "custom-9")
        #expect(body["reasoning_effort"] as? String == "max")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == "Formalize\n\n<dictation>a &amp; &lt;b&gt;</dictation>")
    }

    @Test func unknownRewriteProviderNeverFallsBackToMeta() async {
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"x"}}]}"#))
        let client = chatClient(provider: ProviderID("unregistered"))
        #expect(await client.rewrite(text: "words", prompt: PromptDefinition(template: "Clean up")) == nil)
        #expect(StubChatProtocol.capturedRequest == nil)
    }

    @Test func rewriteRequestKeepsOneProvidersKeyModelAndReasoning() async throws {
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"ok"}}]}"#))
        var config = ProviderConfiguration(
            provider: .grok, values: ["apiKey": "grok-only", "rewriteModel": "grok-custom", "rewriteEffort": "high"])
        let client = RewriteChatClient(
            configuration: config, registry: AppProviderAssembly.defaultRegistry(), session: chatSession())
        config.provider = .meta
        config.values = ["apiKey": "meta-only", "rewriteModel": "muse-custom", "rewriteEffort": "minimal"]
        let prompt = PromptDefinition(template: "Shared instructions {{transcript}}")
        #expect(await client.rewrite(text: "words", prompt: prompt) == "ok")
        let request = try #require(StubChatProtocol.capturedRequest)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-only")
        let raw = try #require(sentBody())
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(body["model"] as? String == "grok-custom")
        #expect(body["reasoning_effort"] as? String == "high")
    }

    @Test func chatBadRequestFallsBackToNil() async {
        StubChatProtocol.stub(status: 400, body: chatJSON(#"{"error":"bad effort"}"#))
        let client = chatClient()
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        #expect(await client.rewrite(text: "raw words", prompt: prompt) == nil)
    }

    @Test func chatTimeoutFallsBackToNil() async {
        StubChatProtocol.stub(
            status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"late"}}]}"#), delay: 30)
        let client = chatClient(timeout: 0.2)
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        let start = Date()
        #expect(await client.rewrite(text: "raw words", prompt: prompt) == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func chatEmptyReplyFallsBackToNil() async {
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"   "}}]}"#))
        #expect(await chatClient().rewrite(text: "raw words", prompt: prompt) == nil)
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[]}"#))
        #expect(await chatClient().rewrite(text: "raw words", prompt: prompt) == nil)
    }

    @Test func chatTruncatedReplyFallsBackToNil() async {
        // A reply cut off at the token cap is not the user's text; the
        // original transcript must be kept rather than a shortened rewrite.
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        StubChatProtocol.stub(
            status: 200,
            body: chatJSON(#"{"choices":[{"message":{"content":"shortened"},"finish_reason":"length"}]}"#))
        #expect(await chatClient().rewrite(text: "raw words", prompt: prompt) == nil)
        // Normal completions carry "stop" (or nothing) and still apply.
        StubChatProtocol.stub(
            status: 200,
            body: chatJSON(#"{"choices":[{"message":{"content":"cleaned"},"finish_reason":"stop"}]}"#))
        #expect(await chatClient().rewrite(text: "raw words", prompt: prompt) == "cleaned")
    }

    @Test func chatMissingKeyMakesNoRequest() async {
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"x"}}]}"#))
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        #expect(await chatClient(key: nil).rewrite(text: "raw words", prompt: prompt) == nil)
        #expect(StubChatProtocol.capturedRequest == nil)
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"x"}}]}"#))
        #expect(await chatClient(key: "").rewrite(text: "raw words", prompt: prompt) == nil)
        #expect(StubChatProtocol.capturedRequest == nil)
    }

    @Test func chatBlankTranscriptMakesNoRequest() async {
        StubChatProtocol.stub(status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"x"}}]}"#))
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        #expect(await chatClient().rewrite(text: "   \n", prompt: prompt) == nil)
        #expect(StubChatProtocol.capturedRequest == nil)
    }

    @Test func chatArrayContentConcatenatesTextParts() async {
        StubChatProtocol.stub(
            status: 200,
            body: chatJSON(#"{"choices":[{"message":{"content":[{"text":"hel"},{"text":"lo"}]}}]}"#))
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        #expect(await chatClient().rewrite(text: "raw words", prompt: prompt) == "hello")
    }

    @Test func chatMalformedBodyFallsBackToNil() async {
        StubChatProtocol.stub(status: 200, body: Data("not-json".utf8))
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        #expect(await chatClient().rewrite(text: "raw words", prompt: prompt) == nil)
    }

    private actor RewriteCallCounter {
        private(set) var callCount = 0

        func increment() { callCount += 1 }
    }

    private func pollRewriteBypass(until condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    @Test @MainActor func noneSelectionSendsNoNetworkTraffic() async {
        StubChatProtocol.stub(
            status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"rewritten"}}]}"#))
        let client = chatClient()
        let counter = RewriteCallCounter()
        let runner: PromptRewrite = { text, prompt in
            await counter.increment()
            return await client.rewrite(text: text, prompt: prompt)
        }
        var settings = AppSettings.defaults
        settings.prompts = [AppEnvironment.examplePrompt(order: 0)]
        #expect(settings.selectedPrompt == nil)
        let audio = GenerationalAudio()
        let inserter = PressInserter()
        let loop = DictationOrchestrator(
            audio: audio,
            inserter: inserter,
            makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
            settings: settings,
            config: ProviderConfiguration(provider: .mock, values: ["apiKey": "k"]),
            pressStarter: {
                audio.start()
                return nil
            },
            pressEnder: { audio.stop() },
            rewriteRunner: runner)
        await loop.pressBegan()
        audio.emit(PCMFrame(samples: [Int16](repeating: 2000, count: 1600)))
        await loop.pressEnded()
        #expect(await pollRewriteBypass { inserter.inserts.count == 1 })
        #expect(inserter.inserts == ["hello world "])
        #expect(await counter.callCount == 0)
        #expect(StubChatProtocol.capturedRequest == nil)
    }

    @Test @MainActor func examplePromptIsAnUnselectedNormalPrompt() {
        let example = AppEnvironment.examplePrompt(order: 3)
        #expect(example.order == 3)
        #expect(example.template.contains(RewritePromptRenderer.placeholder))
        #expect(example.template.contains("ums"))
    }

    @Test func chatHardDeadlineBoundsATricklingServer() async {
        // The per-request timeout is an idle timeout; a server that stalls
        // inside a single request must still be cut off by the wall-clock
        // deadline so "Rewriting…" cannot block new presses indefinitely.
        StubChatProtocol.stub(
            status: 200, body: chatJSON(#"{"choices":[{"message":{"content":"late"}}]}"#), delay: 30)
        let client = chatClient(timeout: 20, deadline: 0.2)
        let prompt = PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)
        let start = Date()
        #expect(await client.rewrite(text: "raw words", prompt: prompt) == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }

}
