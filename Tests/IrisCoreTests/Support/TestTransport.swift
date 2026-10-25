import Foundation
import IrisCore
import IrisProviders

/// Responds to the protocol: ACK on opening, scripted completion on the end
/// marker. Live events can also be injected while audio is still being sent.
final class TestTransport: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [TransportMessage] = []
    private var connected = false
    private var closed = false
    private var continuation: AsyncThrowingStream<TransportMessage, Error>.Continuation?
    private var tail: [Data] = []
    /// End marker arrived before `messages()` attached (or after `close()`):
    /// replay the tail and completion on attach instead of dropping them.
    private var endReceived = false
    let serverFrames: [Data]
    let hang: Bool
    let deliverCount: Int?
    let connectError: Error?
    let writeError: Error?
    /// When set, every receive-side completion finishes the stream by
    /// throwing this error instead of ending cleanly — modeling the real
    /// socket, where a server close surfaces from `receive()` as an error.
    let closeError: Error?

    init(
        serverFrames: [Data] = [], hang: Bool = false, deliverCount: Int? = nil,
        connectError: Error? = nil, writeError: Error? = nil, closeError: Error? = nil
    ) {
        self.serverFrames = serverFrames
        self.hang = hang
        self.deliverCount = deliverCount
        self.connectError = connectError
        self.writeError = writeError
        self.closeError = closeError
    }
    func connect() async throws {
        if let connectError { throw connectError }
        lock.withLock { connected = true }
    }
    func write(_ data: Data) async throws { try await write(.binary(data)) }
    func write(_ message: TransportMessage) async throws {
        lock.withLock { written.append(message) }
        if let writeError { throw writeError }
        if case .text(let text) = message, text.contains("endStream") || text.contains("audio.done") {
            let pending = lock.withLock { () -> AsyncThrowingStream<TransportMessage, Error>.Continuation? in
                endReceived = true
                return continuation
            }
            // No subscriber yet: messages() replays the tail and completion
            // from serverFrames on attach (endReceived), so nothing is lost.
            guard let sink = pending else { return }
            let remaining = lock.withLock { tail }
            for data in remaining { sink.yield(Self.control(data)) }
            if !hang, deliverCount == nil { Self.finish(sink, with: closeError) }
        }
    }
    func close() async {
        let sink = lock.withLock {
            closed = true
            return continuation
        }
        sink?.finish()
    }
    func messages() -> AsyncThrowingStream<TransportMessage, Error> {
        AsyncThrowingStream { sink in
            let deliverable = deliverCount.map { Array(serverFrames.prefix($0)) } ?? serverFrames
            let ack = deliverable.firstIndex {
                MetaWireProtocol.isHandshakeAck($0) || GrokWireProtocol.isReadyAck($0)
            }
            struct Replay {
                var tail: [Data]
                var endArrived: Bool
                var didClose: Bool
            }
            let replay = lock.withLock { () -> Replay in
                continuation = sink
                tail = ack.map { Array(deliverable.dropFirst($0 + 1)) } ?? []
                let end = endReceived
                endReceived = false
                return Replay(tail: tail, endArrived: end, didClose: closed)
            }
            if hang, deliverCount == nil, !replay.endArrived, !replay.didClose { return }
            let initial = ack.map { Array(deliverable.prefix($0 + 1)) } ?? deliverable
            for data in initial { sink.yield(Self.control(data)) }
            if replay.endArrived {
                for data in replay.tail { sink.yield(Self.control(data)) }
            }
            // A close always completes the stream, mirroring close(). An
            // end marker or a missing ACK completes it under the same
            // live-subscriber rule the write path uses.
            if replay.didClose {
                Self.finish(sink, with: closeError)
            } else if !hang, deliverCount == nil, replay.endArrived || ack == nil {
                Self.finish(sink, with: closeError)
            }
        }
    }
    func emit(_ json: String) { lock.withLock { continuation }?.yield(.text(json)) }

    /// Finishes the live receive stream by throwing, modeling a socket that
    /// dies mid-stream rather than a clean server close.
    func emitFailure(_ error: Error) {
        lock.withLock { continuation }?.finish(throwing: error)
    }

    private static func finish(
        _ sink: AsyncThrowingStream<TransportMessage, Error>.Continuation, with error: Error?
    ) {
        if let error { sink.finish(throwing: error) } else { sink.finish() }
    }

    /// Control frames are text on the real transport (`.string` frames);
    /// audio is binary. Preserve that variant here so codecs cannot rely on
    /// flattened bytes.
    private static func control(_ data: Data) -> TransportMessage {
        if let text = String(data: data, encoding: .utf8) { return .text(text) }
        return .binary(data)
    }
    var writes: [Data] { lock.withLock { written.map(\.data) } }
    var messagesWritten: [TransportMessage] { lock.withLock { written } }
    var didConnect: Bool { lock.withLock { connected } }
    var didClose: Bool { lock.withLock { closed } }
}
