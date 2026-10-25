import Foundation

/// Typed WebSocket framing. Control payloads are text; audio is binary.
/// Providers choose the variant explicitly so transports never guess from
/// payload bytes.
public enum TransportMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)

    public var data: Data {
        switch self {
        case .text(let text): return Data(text.utf8)
        case .binary(let data): return data
        }
    }

    public static func utf8Text(_ data: Data) throws -> TransportMessage {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionError(kind: .decoding, message: "Control frame is not valid UTF-8.")
        }
        return .text(text)
    }
}

/// Sendable byte transport for provider sessions.
///
/// Single-owner and used serially: connect once, interleave writes with a
/// single frames() consumer, then close. Prefer the typed `write(_:)`
/// and `messages()` APIs. Compatibility byte reads flatten framing; byte writes
/// always mean binary, never guessed JSON text.
public protocol ByteStream: Sendable {
    func connect() async throws
    func write(_ message: TransportMessage) async throws
    func close() async
    func messages() -> AsyncThrowingStream<TransportMessage, Error>
}

extension ByteStream {
    public func write(_ data: Data) async throws { try await write(.binary(data)) }
}
