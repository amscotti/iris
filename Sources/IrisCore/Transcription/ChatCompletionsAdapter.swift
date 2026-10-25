import Foundation

/// Reusable wire adapter for chat-completions-compatible providers. Provider
/// modules supply endpoint, role, and capabilities; other APIs implement
/// RewriteAdapter directly without changing the application's HTTP client.
public struct ChatCompletionsAdapter: RewriteAdapter {
    public let descriptor: RewriteDescriptor
    public let endpoint: String
    public let instructionRole: String
    public let maxOutputTokens: Int

    public init(
        descriptor: RewriteDescriptor, endpoint: String, instructionRole: String, maxOutputTokens: Int = 2_000
    ) {
        self.descriptor = descriptor
        self.endpoint = endpoint
        self.instructionRole = instructionRole
        self.maxOutputTokens = min(max(1, maxOutputTokens), Self.maxTokenBudget)
    }

    static let maxTokenBudget = 32_000

    /// Token cap for one rewrite. Reasoning models spend part of it on hidden
    /// reasoning (Meta counts reasoning and output together), so a fixed cap
    /// made high-effort or long rewrites hit the limit and fall back to the
    /// original text. Output room scales with the transcript; reasoning room
    /// with the effort.
    static func tokenBudget(transcript: String, effort: PromptEffort, outputFloor: Int) -> Int {
        let reasoning: Int
        switch effort {
        case .minimal: reasoning = 0
        case .low: reasoning = 2_000
        case .medium: reasoning = 6_000
        case .high: reasoning = 12_000
        case .xhigh, .max: reasoning = 24_000
        default: reasoning = 6_000
        }
        return min(maxTokenBudget, max(outputFloor, transcript.count) + reasoning)
    }

    public func makeRequest(
        text: String, prompt: PromptDefinition, config: ProviderConfiguration
    ) -> RewriteHTTPRequest? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let settings = RewriteConfiguration(config: config, descriptor: descriptor),
            let key = config.apiKey, let url = URL(string: endpoint),
            url.scheme?.lowercased() == "https"
        else { return nil }
        // Reject keys that would split or inject HTTP headers. ProviderConfiguration
        // trims outer whitespace only, so an interior CR/LF or control character
        // must decline the request rather than enter the Authorization header.
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        let payload = ChatRequest(
            model: settings.model,
            messages: [
                ChatMessage(
                    role: instructionRole,
                    content: RewritePromptRenderer.developerMessage(template: prompt.template, transcript: text)),
                ChatMessage(role: "user", content: RewritePromptRenderer.userMessage(transcript: text)),
            ],
            maxTokens: Self.tokenBudget(transcript: text, effort: settings.effort, outputFloor: maxOutputTokens),
            reasoningEffort: settings.effort.rawValue)
        guard let body = try? JSONEncoder().encode(payload) else { return nil }
        return RewriteHTTPRequest(
            url: url, headers: ["Content-Type": "application/json", "Authorization": "Bearer \(key)"], body: body)
    }

    public func responseText(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else { return nil }
        // A reply the server truncated, filtered, or redirected to a tool or
        // refusal is not the user's text: fail open (nil) so the original
        // transcript is inserted instead. Older compatible replies may omit
        // the finish reason, so only a present non-stop reason is rejected.
        let choice = decoded.choices?.first
        if let finishReason = choice?.finishReason, finishReason != "stop" { return nil }
        if choice?.message?.refusal != nil { return nil }
        let reply = (choice?.message?.content?.text ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let unwrapped = Self.stripDictationWrapper(reply)
        return unwrapped.isEmpty ? nil : unwrapped
    }

    /// Some models echo the `<dictation>` prompt wrapper around their reply.
    /// Strip it only when it wraps the entire reply, reversing the renderer's
    /// XML escaping so the inserted text matches what was dictated.
    static func stripDictationWrapper(_ reply: String) -> String {
        let open = "<dictation>"
        let close = "</dictation>"
        guard reply.hasPrefix(open), reply.hasSuffix(close), reply.count >= open.count + close.count
        else { return reply }
        let inner = String(reply.dropFirst(open.count).dropLast(close.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return
            inner
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private struct ChatRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var maxTokens: Int
    var reasoningEffort: String

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

private struct ChatMessage: Encodable {
    var role: String
    var content: String
}

private struct ChatResponse: Decodable { var choices: [ChatChoice]? }
private struct ChatChoice: Decodable {
    var message: ChatReply?
    var finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}
private struct ChatReply: Decodable {
    var content: MessageContent?
    var refusal: String?
}

private struct MessageContent: Decodable {
    var text: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let direct = try? container.decode(String.self) {
            text = direct
            return
        }
        struct Part: Decodable { var text: String? }
        if let parts = try? container.decode([Part].self) {
            text = parts.compactMap(\.text).joined()
            return
        }
        text = ""
    }
}
