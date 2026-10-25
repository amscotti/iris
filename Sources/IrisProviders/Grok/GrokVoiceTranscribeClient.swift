import Foundation
import IrisCore

/// Grok streaming STT client over an injected byte transport.
///
/// Flow per utterance: connect (Bearer is on the transport handshake), wait
/// for `transcript.created`, continuously decode transcripts/errors while
/// sending PCM, then write `audio.done` and await `transcript.done` on release.
public final class GrokVoiceTranscribeClient: TranscriptionClient, Sendable {

    public static let endpointHost = "api.x.ai"
    public static let endpointPath = "/v1/stt"

    /// Bounded wait after `audio.done` for `transcript.done`.
    public static let finishTimeoutSeconds = 15.0
    /// Bounded wait for `transcript.created` before sending audio.
    public static let ackTimeoutSeconds = 10.0

    /// Streaming STT URL. Config rides as query items; the API key is not
    /// in the URL (it belongs on the WebSocket `Authorization` header).
    public static func endpointURL(
        language: String = GrokLanguage.auto, keyterms: [String] = [],
        model: String = GrokSessionConfig.defaultModel
    ) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = endpointHost
        components.path = endpointPath
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "sample_rate", value: String(GrokSessionConfig.sampleRate)),
            URLQueryItem(name: "encoding", value: GrokSessionConfig.encoding),
            URLQueryItem(name: "interim_results", value: "true"),
        ]
        // Unknown tokens fall back to Auto: omit the parameter so the model
        // detects speech instead of sending a code the API does not know.
        let code = GrokLanguage.selection(from: language)
        if !code.isEmpty {
            items.append(URLQueryItem(name: "language", value: code))
        }
        for term in keyterms {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items
        // URLComponents leaves "+" literal (RFC 3986 allows it in a query),
        // but form-style decoders such as xAI's read it as a space, which
        // would turn a keyterm like "C++" into "C  ". Spaces are already %20.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        // Components above are always valid.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }

    public static func endpointURL(from config: ProviderConfiguration) -> URL {
        let language = GrokLanguage.normalize(
            config.string(ProviderConfiguration.Key.languageBias) ?? GrokLanguage.auto)
        let keyterms = GrokSessionConfig.sanitizedKeyterms(
            config.stringList(ProviderConfiguration.Key.keywords))
        let model = config.nonBlankString(
            ProviderConfiguration.Key.model, default: GrokSessionConfig.defaultModel)
        return endpointURL(language: language, keyterms: keyterms, model: model)
    }

    private let driver: SessionDriver

    public init(transport: any ByteStream) {
        driver = SessionDriver(
            transport: transport, ackTimeout: Self.ackTimeoutSeconds, finishTimeout: Self.finishTimeoutSeconds)
    }

    public func start(config: ProviderConfiguration) async throws {
        _ = try GrokSessionConfig(from: config)
        do {
            try await driver.start(codec: try GrokSpeechCodec())
        } catch {
            if error is CancellationError { throw error }
            throw Self.classifyTransportError(error)
        }
    }

    public func cancel() async {
        await driver.cancel()
    }

    public func sendAudio(_ frame: PCMFrame) async throws {
        try await driver.sendAudio(frame)
    }

    public func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { driver.events() }
    public func endAudio() async throws { try await driver.endAudio() }

    static func classifyTransportError(_ error: Error) -> TranscriptionError {
        let providerAuth = TranscriptionError.auth("Grok rejected the API key. Check Settings → Providers.")
        if let failure = error as? TranscriptionError {
            if failure.kind == .authentication, failure.message == TranscriptionError.genericAuthMessage {
                return providerAuth
            }
            return failure
        }
        if let classified = TranscriptionError.classifiedTransportError(in: error.localizedDescription) {
            return classified.isAuthFailure ? providerAuth : classified
        }
        return TranscriptionError(kind: .network, message: error.localizedDescription)
    }

}

struct GrokSpeechCodec: SpeechSessionCodec {
    private var transcript = GrokTranscriptAccumulator()
    var handshake: TransportMessage? { nil }
    let endMarker: TransportMessage
    init() throws {
        endMarker = try .utf8Text(GrokWireProtocol.encodeAudioDone())
    }
    var completesOnClose: Bool { false }
    func isReady(_ message: TransportMessage) -> Bool {
        guard case .text = message else { return false }
        return GrokWireProtocol.isReadyAck(message.data)
    }
    mutating func decode(_ message: TransportMessage) -> TranscriptionEvent? {
        guard case .text = message else { return nil }
        return GrokWireProtocol.decodeServerEvent(message.data, accumulating: &transcript)
    }
}
