import Foundation
import IrisCore

/// Explicit no-connection transport for providers that ignore platform I/O.
final class DiscardedTransport: ByteStream, Sendable {
    func connect() async throws {}
    func write(_: TransportMessage) async throws {}
    func close() async {}
    func messages() -> AsyncThrowingStream<TransportMessage, Error> { AsyncThrowingStream { $0.finish() } }
}
