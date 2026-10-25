import Foundation
import Testing

@testable import IrisCore

private struct TimingCodec: SpeechSessionCodec {
    var handshake: TransportMessage? { nil }
    var endMarker: TransportMessage { .text("end") }
    var completesOnClose: Bool { false }
    func isReady(_ message: TransportMessage) -> Bool { message == .text("ready") }
    func decode(_ message: TransportMessage) -> TranscriptionEvent? { nil }
}

private final class TimingTransport: ByteStream, Sendable {
    let connected = AsyncStream.makeStream(of: Void.self)
    let subscribed = AsyncStream.makeStream(of: Void.self)
    let incoming = AsyncThrowingStream.makeStream(of: TransportMessage.self, throwing: Error.self)
    let written = TestValue<[TransportMessage]>([])
    let closes = TestValue(0)

    func connect() async throws { connected.continuation.yield(()) }
    func messages() -> AsyncThrowingStream<TransportMessage, Error> {
        subscribed.continuation.yield(())
        return incoming.stream
    }
    func write(_ message: TransportMessage) async throws { written.update { $0.append(message) } }
    func close() async {
        closes.update { $0 += 1 }
        incoming.continuation.finish()
    }
    func acknowledge() { incoming.continuation.yield(.text("ready")) }
}

private func expectRetainedTimingFailure(_ driver: SessionDriver, failure: TranscriptionError) async {
    var emitted: [TranscriptionEvent] = []
    do {
        for try await event in driver.events() { emitted.append(event) }
        Issue.record("The duration limit must fail the event stream")
    } catch let streamed as TranscriptionError {
        #expect(streamed == failure)
    } catch {
        Issue.record("Unexpected duration-limit error: \(error)")
    }
    #expect(emitted == [.error(failure)])
    await #expect(throws: failure) { try await driver.endAudio() }
}

@Test func streamingDurationStartsAtDelayedAcknowledgement() async throws {
    let transport = TimingTransport()
    let clock = TestValue(100.0)
    let started = TestValue(false)
    let driver = SessionDriver(
        transport: transport, ackTimeout: 5, finishTimeout: 5, maxSessionSeconds: 60,
        uptime: { clock.get() })
    let frame = PCMFrame(samples: [1, -1])
    let failure = TranscriptionError(
        kind: .streamLimit, message: "Speech session reached the 1-minute limit. Start a new take to continue.")
    defer {
        transport.incoming.continuation.finish()
        transport.connected.continuation.finish()
        transport.subscribed.continuation.finish()
    }
    let checking = Task {
        let starting = Task {
            try await driver.start(codec: TimingCodec())
            started.update { $0 = true }
        }
        defer { starting.cancel() }
        do {
            var connected = transport.connected.stream.makeAsyncIterator()
            try #require(await connected.next() != nil)
            var subscribed = transport.subscribed.stream.makeAsyncIterator()
            try #require(await subscribed.next() != nil)
            #expect(!started.get())
            #expect(transport.written.get().isEmpty)
            // Connection is complete, but ACK is still withheld. Advance the
            // injected monotonic clock far beyond the entire streaming budget.
            clock.update { $0 = 1000 }
            transport.acknowledge()
            try await starting.value
            #expect(started.get())

            clock.update { $0 = 1059 }
            try await driver.sendAudio(frame)
            #expect(transport.written.get() == [.binary(frame.asData())])
            clock.update { $0 = 1060 }
            await #expect(throws: failure) { try await driver.sendAudio(frame) }
            #expect(transport.written.get() == [.binary(frame.asData())])
            await expectRetainedTimingFailure(driver, failure: failure)
        } catch {
            await driver.cancel()
            throw error
        }
        await driver.cancel()
        #expect(transport.closes.get() > 0)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test func defaultMonotonicClockExpiresAPositiveStreamingBudget() async throws {
    let transport = TimingTransport()
    // Omit uptime to exercise the actual ProcessInfo default, not an injected
    // clock or the trivial zero-duration guard.
    let driver = SessionDriver(
        transport: transport, ackTimeout: 5, finishTimeout: 5, maxSessionSeconds: 0.02)
    let failure = TranscriptionError(
        kind: .streamLimit, message: "Speech session reached the 0-minute limit. Start a new take to continue.")
    defer {
        transport.incoming.continuation.finish()
        transport.connected.continuation.finish()
        transport.subscribed.continuation.finish()
    }
    let checking = Task {
        let starting = Task { try await driver.start(codec: TimingCodec()) }
        defer { starting.cancel() }
        do {
            var subscribed = transport.subscribed.stream.makeAsyncIterator()
            try #require(await subscribed.next() != nil)
            transport.acknowledge()
            try await starting.value
            // This sleep advances the real clock; it is not an ordering gate.
            try await Task.sleep(for: .milliseconds(50))
            await #expect(throws: failure) { try await driver.sendAudio(PCMFrame(samples: [1, -1])) }
            #expect(transport.written.get().isEmpty)
            await expectRetainedTimingFailure(driver, failure: failure)
        } catch {
            await driver.cancel()
            throw error
        }
        await driver.cancel()
        #expect(transport.closes.get() > 0)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}
