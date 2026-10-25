import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Byte-stream fixture shaped like a real one-shot server: it serves exactly
/// one session (handshake ACK, partials, final, then close) and fails loudly
/// on any second use, so a test catches transport/client reuse across
/// presses instead of silently absorbing it.
final class OneShotServerTransport: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [Data]
    private let transport: TestTransport
    private var connects = 0
    private var frameCalls = 0
    private var written: [Data] = []
    private var closedCount = 0
    private var reuseViolations = 0

    init(script: [Data]) {
        self.script = script
        self.transport = TestTransport(serverFrames: script)
    }

    func connect() async throws {
        let attempt = guarded {
            connects += 1
            return connects
        }
        if attempt > 1 {
            guarded { reuseViolations += 1 }
            throw TranscriptionError(kind: .invalidState, message: "One-shot server: second connect on one transport.")
        }
        try await transport.connect()
    }

    func write(_ message: TransportMessage) async throws {
        guarded { written.append(message.data) }
        try await transport.write(message)
    }

    func close() async {
        guarded { closedCount += 1 }
        await transport.close()
    }

    private func guarded<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func messages() -> AsyncThrowingStream<TransportMessage, Error> {
        lock.lock()
        frameCalls += 1
        let call = frameCalls
        if call > 1 { reuseViolations += 1 }
        lock.unlock()
        guard call == 1 else {
            return AsyncThrowingStream { $0.finish() }
        }
        return transport.messages()
    }

    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connects
    }

    var frameCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCalls
    }

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closedCount
    }

    var violations: Int {
        lock.lock()
        defer { lock.unlock() }
        return reuseViolations
    }
}

final class TransportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OneShotServerTransport] = []

    func add(_ transport: OneShotServerTransport) {
        lock.lock()
        stored.append(transport)
        lock.unlock()
    }

    var all: [OneShotServerTransport] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func oneShotJSON(_ text: String) -> Data { Data(text.utf8) }

private func oneShotScript() -> [Data] {
    [
        oneShotJSON(#"{"sessionId":"s-1"}"#),
        oneShotJSON(#"{"type":"transcript","transcript":"hello","final":false}"#),
        oneShotJSON(#"{"type":"transcript","transcript":"hello world","final":true}"#),
    ]
}

private func oneShotConfig() -> ProviderConfiguration {
    ProviderConfiguration(
        provider: .meta, values: ["apiKey": "k", "audioEncoding": "PCM_16KHZ"])
}

private func oneShotFrame() -> PCMFrame {
    PCMFrame(samples: [Int16](repeating: 500, count: 1600))
}

private func waitForOneShot(_ check: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !check() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

private func driveOnePress(
    loop: DictationOrchestrator, transports: TransportCollector, audioWrites: Int
) async -> Bool {
    await loop.pressBegan()
    let settled = await waitForOneShot {
        let seen = transports.all
        guard let current = seen.last else { return false }
        // Handshake plus at least one audio frame reached this press's server.
        return current.writes.count >= 1 + audioWrites
    }
    await loop.pressEnded()
    return settled
}

@Test func twoPressesOverOneShotServersBothComplete() async {
    let transports = TransportCollector()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [oneShotFrame(), oneShotFrame()]),
        inserter: inserter,
        makeService: { _ in
            let transport = OneShotServerTransport(script: oneShotScript())
            transports.add(transport)
            let client = MetaVoiceTranscribeClient(transport: transport)
            return TranscriptionService(client: client, completion: .finalEvent)
        },
        settings: .defaults,
        config: oneShotConfig())

    #expect(await driveOnePress(loop: loop, transports: transports, audioWrites: 1))
    #expect(await driveOnePress(loop: loop, transports: transports, audioWrites: 1))

    let seen = transports.all
    #expect(seen.count == 2)
    for transport in seen {
        #expect(transport.connectCount == 1)
        #expect(transport.frameCallCount == 1)
        #expect(transport.violations == 0)
        #expect(transport.closeCount >= 1)
        let texts = transport.writes.compactMap { String(data: $0, encoding: .utf8) }
        #expect(texts.first?.contains("audioEncoding") == true)
        #expect(texts.last?.contains("endStream") == true)
    }
    #expect(inserter.inserts == ["hello world ", "hello world "])
    #expect(await loop.isPressActive == false)
}
