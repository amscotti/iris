import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private func responseAdapter() -> ChatCompletionsAdapter {
    ChatCompletionsAdapter(
        descriptor: GrokProvider.rewriteDescriptor,
        endpoint: "https://api.x.ai/v1/chat/completions", instructionRole: "system")
}

private func chatResponse(finishReason: String? = nil, refusal: String? = nil) throws -> Data {
    var message: [String: Any] = ["content": "rewritten"]
    if let refusal { message["refusal"] = refusal }
    var choice: [String: Any] = ["message": message]
    if let finishReason { choice["finish_reason"] = finishReason }
    return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
}

@Test func rewriteResponseAcceptsStopAndMissingFinishReason() throws {
    let adapter = responseAdapter()
    #expect(adapter.responseText(from: try chatResponse(finishReason: "stop")) == "rewritten")
    #expect(adapter.responseText(from: try chatResponse()) == "rewritten")
}

@Test(arguments: ["length", "content_filter", "tool_calls", "function_call"])
func rewriteResponseRejectsNonStopFinishReason(_ finishReason: String) throws {
    #expect(responseAdapter().responseText(from: try chatResponse(finishReason: finishReason)) == nil)
}

@Test func rewriteResponseRejectsNonnilRefusal() throws {
    let response = try chatResponse(finishReason: "stop", refusal: "I cannot help with that.")
    #expect(responseAdapter().responseText(from: response) == nil)
}
