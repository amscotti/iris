import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private final class TerminalDeliveryRaceClient: TranscriptionClient, Sendable {
    let sending: ManualGate
    let sendCancelled = AsyncStream.makeStream(of: Void.self)
    let failedWhileCancelled = TestValue(false)
    let endings = TestValue(0)
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)

    init(sending: ManualGate) { self.sending = sending }
    func start(config: ProviderConfiguration) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }

    func sendAudio(_ frame: PCMFrame) async throws {
        try await withTaskCancellationHandler {
            // Ignore cancellation until explicitly released, then model a
            // transport write failing because terminal teardown closed it.
            await sending.wait()
            failedWhileCancelled.update { $0 = Task.isCancelled }
            throw URLError(.networkConnectionLost)
        } onCancel: {
            sendCancelled.continuation.yield(())
        }
    }

    func endAudio() async throws { endings.update { $0 += 1 } }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test(arguments: [
    TranscriptionError.auth("authentication rejected"),
    TranscriptionError(kind: .rateLimited, message: "rate limit exceeded"),
])
func terminalEventWinsTheAudioDeliveryRace(failure: TranscriptionError) async throws {
    let sending = ManualGate()
    let watchdog = sending.watchdog()
    let client = TerminalDeliveryRaceClient(sending: sending)
    let service = TranscriptionService(client: client, shutdownTimeout: 5)
    defer {
        watchdog.cancel()
        sending.release()
        client.channel.continuation.finish()
    }
    // Inherit the test context for assertions; bound the task externally across
    // startup, signals, the reply, and cleanup. Always retire the parked send.
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .mock))
        let appending = Task { try await service.appendAudio(PCMFrame(samples: [1, -1])) }
        defer {
            appending.cancel()
            sending.release()
        }
        await sending.waitUntilEntered()
        client.channel.continuation.yield(.error(failure))

        var seen: [PushToTalkState] = []
        var sawError = false
        while let state = await states.next() {
            seen.append(state)
            if case .error = state { sawError = true }
            if sawError && state == .idle { break }
        }
        // Observe actual service consumption, not just the client's yield.
        try #require(seen == [.idle, .recording(level: 0), .error(failure.message), .idle])
        #expect(await service.terminalOutcome == .failed(failure))
        var cancellation = client.sendCancelled.stream.makeAsyncIterator()
        try #require(await cancellation.next() != nil)
        try #require(!sending.isReleased)
        try #require(!appending.isCancelled)

        sending.release()
        // fail() already preserves the outcome without appendAudio's guard.
        // The distinguishing regression is the reply to an uncancelled caller.
        await #expect(throws: CancellationError.self) { try await appending.value }
        #expect(!appending.isCancelled)
        #expect(client.failedWhileCancelled.get())
        #expect(await service.terminalOutcome == .failed(failure))
        #expect(await service.finish() == .failed(failure))
        #expect(await service.requiresRestart == false)
        #expect(await service.lastFinal == nil)
        #expect(client.endings.get() == 0)

        // Cancel only after the reply/outcome checks: an earlier cancel would
        // bump generation and mask a missing outcome guard. Its idle is also
        // a barrier: any extra error/recording event is queued ahead of it.
        #expect(await service.cancel() == .clean)
        #expect(await states.next() == .idle)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

private struct RaceCodec: SpeechSessionCodec {
    var handshake: TransportMessage? { nil }
    var endMarker: TransportMessage { .text("end") }
    var completesOnClose: Bool { false }
    func isReady(_ message: TransportMessage) -> Bool { message == .text("ready") }
    func decode(_ message: TransportMessage) -> TranscriptionEvent? {
        if case .text(let text) = message, text.hasPrefix("final ") {
            return .final(String(text.dropFirst(6)))
        }
        return nil
    }
}

private final class ResetTransport: ByteStream, Sendable {
    let failWrites = TestValue(false)
    let incoming = AsyncThrowingStream.makeStream(of: TransportMessage.self, throwing: Error.self)
    func connect() async throws {}
    func messages() -> AsyncThrowingStream<TransportMessage, Error> { incoming.stream }
    func write(_ message: TransportMessage) async throws {
        if failWrites.get() {
            throw TranscriptionError(kind: .network, message: "connection reset")
        }
    }
    func close() async { incoming.continuation.finish() }
}

@Test func aWriteFailureRacingTheFinalMessageLetsTheFinalWin() async throws {
    let transport = ResetTransport()
    let driver = SessionDriver(transport: transport, ackTimeout: 5, finishTimeout: 5)
    transport.incoming.continuation.yield(.text("ready"))
    try await driver.start(codec: RaceCodec())
    transport.failWrites.update { $0 = true }
    let sending = Task { try await driver.sendAudio(PCMFrame(samples: [1, -1])) }
    // The write fails while the reader has not yet delivered the final the
    // server already sent: the reconcile drain must let it settle.
    try await Task.sleep(nanoseconds: 50_000_000)
    transport.incoming.continuation.yield(.text("final spoken words"))
    try await AsyncDeadline.run(seconds: 5) { _ = try await sending.value }
    var events = driver.events().makeAsyncIterator()
    let delivered = try await events.next()
    #expect(delivered == .final("spoken words"))
}
