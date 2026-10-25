import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

enum ConformancePhase: Sendable { case complete, startup, audio, finish }

struct ProviderConformanceFixture: Sendable {
    let provider: any DictationProvider
    let config: ProviderConfiguration
    let ack: String?
    let final: String?
    let endKind: String?

    init(id: ProviderID) throws {
        provider = try #require(AppProviderAssembly.defaultRegistry().provider(for: id))
        config = ProviderConfiguration(
            provider: id, values: provider.descriptor.defaultValues().merging(["apiKey": "fixture"]) { _, new in new })
        switch id {
        case .meta:
            ack = #"{"sessionId":"conformance"}"#
            final = #"{"type":"transcript","transcript":"conformance","final":true}"#
            endKind = "endStream"
        case .grok:
            ack = #"{"type":"transcript.created"}"#
            final = #"{"type":"transcript.done","text":"conformance"}"#
            endKind = "audio.done"
        case .mock:
            ack = nil
            final = nil
            endKind = nil
        default:
            Issue.record("Add a wire fixture for the newly assembled provider: \(id.name)")
            throw MissingFixture()
        }
    }
    private struct MissingFixture: Error {}
}

final class ConformanceTransport: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var sent: [TransportMessage] = []
    private let fixture: ProviderConformanceFixture
    private let blocked: ConformancePhase
    private let channel = AsyncThrowingStream.makeStream(of: TransportMessage.self, throwing: Error.self)
    private let pendingWrite = AsyncThrowingStream.makeStream(of: Void.self, throwing: Error.self)
    private let checkpoints = AsyncStream.makeStream(of: ConformancePhase.self)

    init(_ fixture: ProviderConformanceFixture, blocked: ConformancePhase = .complete) {
        self.fixture = fixture
        self.blocked = blocked
    }
    var didClose: Bool { lock.withLock { closed } }
    var messagesWritten: [TransportMessage] { lock.withLock { sent } }
    func connect() async throws {
        checkpoints.continuation.yield(.startup)
        if blocked != .startup, let ack = fixture.ack { channel.continuation.yield(.text(ack)) }
    }
    func write(_ message: TransportMessage) async throws {
        lock.withLock { sent.append(message) }
        if case .binary = message {
            checkpoints.continuation.yield(.audio)
            if blocked == .audio {
                for try await _ in pendingWrite.stream {}
                throw CancellationError()
            }
        }
        let object = try? JSONSerialization.jsonObject(with: message.data) as? [String: Any]
        if let endKind = fixture.endKind, object?["type"] as? String == endKind {
            checkpoints.continuation.yield(.finish)
            if blocked != .finish, let final = fixture.final { channel.continuation.yield(.text(final)) }
        }
    }
    func close() async {
        lock.withLock { closed = true }
        pendingWrite.continuation.finish(throwing: CancellationError())
        channel.continuation.finish()
    }
    func messages() -> AsyncThrowingStream<TransportMessage, Error> { channel.stream }
    func reached(_ phase: ConformancePhase) async {
        for await checkpoint in checkpoints.stream where checkpoint == phase { return }
    }
}
