import Foundation
import IrisCore

/// Voice transcribe client over an injected byte transport.
///
/// Flow per utterance: connect, write the JSON handshake, wait for the bare
/// `{"sessionId"}` ACK, then continuously decode server events while sending
/// PCM. On release, `endStream` completes the owned session with a bounded wait.
public final class MetaVoiceTranscribeClient: TranscriptionClient, Sendable {

    /// Base endpoint. The session id rides as a query item for correlation.
    public static let endpointHost = "api.meta.ai"
    public static let endpointPath = "/v1/asr/realtime"

    public static func endpointURL(sessionId: String?) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = endpointHost
        components.path = endpointPath
        if let sessionId, !sessionId.isEmpty {
            components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        }
        // Components above are always valid.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }

    /// Bounded wait after `endStream`. Fifteen seconds covers Meta's
    /// five-second audio lead plus network time.
    public static let finishTimeoutSeconds = 15.0
    /// Bounded wait for the handshake ACK before sending audio.
    public static let ackTimeoutSeconds = 5.0

    private let driver: SessionDriver

    public init(transport: any ByteStream, finishTimeout: Double = MetaVoiceTranscribeClient.finishTimeoutSeconds) {
        driver = SessionDriver(transport: transport, ackTimeout: Self.ackTimeoutSeconds, finishTimeout: finishTimeout)
    }

    public func start(config: ProviderConfiguration) async throws {
        let session = try MetaSessionConfig(from: config)
        do {
            try await driver.start(codec: try MetaSpeechCodec(session: session))
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
        let providerAuth = TranscriptionError.auth("Meta rejected the API key. Check Settings → Providers.")
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

struct MetaSpeechCodec: SpeechSessionCodec {
    let session: MetaSessionConfig
    let handshake: TransportMessage?
    let endMarker: TransportMessage
    init(session: MetaSessionConfig) throws {
        self.session = session
        handshake = try .utf8Text(MetaWireProtocol.encodeHandshake(config: session))
        endMarker = try .utf8Text(MetaWireProtocol.encodeEndStream())
    }
    var completesOnClose: Bool { session.mode != .pushToTalk }
    func isReady(_ message: TransportMessage) -> Bool {
        guard case .text = message else { return false }
        return MetaWireProtocol.isHandshakeAck(message.data)
    }
    func decode(_ message: TransportMessage) -> TranscriptionEvent? {
        guard case .text = message else { return nil }
        return MetaWireProtocol.decodeServerEvent(message.data, mode: session.mode)
    }
}
