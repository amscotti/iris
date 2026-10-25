import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

private enum QueuedProviderFailure: String, CaseIterable, Sendable {
    case authentication, rateLimited, serverClosed

    var error: TranscriptionError {
        switch self {
        case .authentication: return .auth("authentication rejected")
        case .rateLimited: return TranscriptionError(kind: .rateLimited, message: "rate limit exceeded")
        case .serverClosed: return .closed("server closed during audio delivery")
        }
    }
}

private enum DeliveryTeardown: String, CaseIterable, Sendable {
    case taskCancellation, urlCancellation, connectionLost

    var error: any Error {
        switch self {
        case .taskCancellation: return CancellationError()
        case .urlCancellation: return URLError(.cancelled)
        case .connectionLost: return URLError(.networkConnectionLost)
        }
    }
}

private final class HeldDeliveryTransport: ByteStream, Sendable {
    let sending = ManualGate()
    let writeCancelled = AsyncStream.makeStream(of: Void.self)
    let incoming = AsyncThrowingStream.makeStream(of: TransportMessage.self, throwing: Error.self)
    let written = TestValue<[TransportMessage]>([])
    let closes = TestValue(0)
    let teardown: DeliveryTeardown

    init(teardown: DeliveryTeardown) { self.teardown = teardown }
    func connect() async throws {
        incoming.continuation.yield(.text(#"{"type":"transcript.created"}"#))
    }
    func messages() -> AsyncThrowingStream<TransportMessage, Error> { incoming.stream }
    func write(_ message: TransportMessage) async throws {
        written.update { $0.append(message) }
        try await withTaskCancellationHandler {
            // Hold the write even after SessionDriver cancels it, then return
            // the teardown artifact rather than the reader's semantic error.
            await sending.wait()
            throw teardown.error
        } onCancel: {
            writeCancelled.continuation.yield(())
        }
    }
    func close() async {
        closes.update { $0 += 1 }
        incoming.continuation.finish()
    }
    func publish(_ failure: QueuedProviderFailure) {
        switch failure {
        case .authentication:
            incoming.continuation.yield(.text(#"{"type":"error","code":401,"message":"authentication rejected"}"#))
        case .rateLimited:
            incoming.continuation.yield(.text(#"{"type":"error","code":429,"message":"rate limit exceeded"}"#))
        case .serverClosed:
            incoming.continuation.finish(throwing: failure.error)
        }
    }
}

/// The real provider/driver runs normally, but its event stream is not drained
/// into the service until the test explicitly opens this delivery gate.
private final class GatedProviderDeliveryClient: TranscriptionClient, Sendable {
    let base: any TranscriptionClient
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    let forwarded = TestValue<[TranscriptionEvent]>([])
    let endings = TestValue(0)

    init(transport: HeldDeliveryTransport) { base = GrokVoiceTranscribeClient(transport: transport) }
    func start(config: ProviderConfiguration) async throws { try await base.start(config: config) }
    func sendAudio(_ frame: PCMFrame) async throws { try await base.sendAudio(frame) }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        endings.update { $0 += 1 }
        try await base.endAudio()
    }
    func cancel() async {
        await base.cancel()
        channel.continuation.finish(throwing: CancellationError())
    }
    func forwardQueuedEvents() async throws {
        do {
            for try await event in base.events() {
                forwarded.update { $0.append(event) }
                channel.continuation.yield(event)
            }
            channel.continuation.finish()
        } catch {
            channel.continuation.finish(throwing: error)
            throw error
        }
    }
}

@Test(arguments: QueuedProviderFailure.allCases, DeliveryTeardown.allCases)
private func queuedProviderTerminalWinsBeforeTheServiceReaderRuns(
    failure: QueuedProviderFailure, teardown: DeliveryTeardown
) async throws {
    let transport = HeldDeliveryTransport(teardown: teardown)
    let watchdog = transport.sending.watchdog()
    let client = GatedProviderDeliveryClient(transport: transport)
    let service = TranscriptionService(client: client)
    let frame = PCMFrame(samples: [1, -1])
    defer {
        watchdog.cancel()
        transport.sending.release()
        transport.incoming.continuation.finish()
        client.channel.continuation.finish()
    }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .grok, values: ["apiKey": "fixture"]))
        let appending = Task { try await service.appendAudio(frame) }
        defer {
            appending.cancel()
            transport.sending.release()
        }
        await transport.sending.waitUntilEntered()
        transport.publish(failure)
        var cancelled = transport.writeCancelled.stream.makeAsyncIterator()
        try #require(await cancelled.next() != nil)
        // Writer cancellation is signalled only after the actual driver has
        // retained and queued the terminal. The service still cannot read it.
        #expect(client.forwarded.get().isEmpty)
        #expect(await service.terminalOutcome == nil)
        transport.sending.release()
        await #expect(throws: failure.error) { try await appending.value }
        #expect(!appending.isCancelled)
        #expect(client.forwarded.get().isEmpty)
        #expect(await service.terminalOutcome == .failed(failure.error))
        #expect(await service.currentState == .idle)

        // Open delivery only after appendAudio's reply and outcome assertions.
        await #expect(throws: failure.error) { try await client.forwardQueuedEvents() }
        #expect(client.forwarded.get() == [.error(failure.error)])
        var seen: [PushToTalkState] = []
        for _ in 0..<4 {
            if let state = await states.next() { seen.append(state) }
        }
        #expect(seen == [.idle, .recording(level: 0), .error(failure.error.message), .idle])
        #expect(await service.finish() == .failed(failure.error))
        #expect(await service.requiresRestart == false)
        #expect(await service.lastFinal == nil)
        #expect(client.endings.get() == 0)
        #expect(transport.written.get() == [.binary(frame.asData())])
        #expect(transport.closes.get() > 0)
        #expect(await service.cancel() == .clean)
        #expect(await states.next() == .idle)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test func aStandaloneTransportWriteFailureSurfacesTheClassifiedDisconnectCopy() async throws {
    let transport = HeldDeliveryTransport(teardown: .connectionLost)
    let watchdog = transport.sending.watchdog()
    let client = GatedProviderDeliveryClient(transport: transport)
    let service = TranscriptionService(client: client)
    // A connection-lost write failure classifies on the write path too, so
    // the pill shows the friendly disconnect copy instead of a raw NSError.
    let failure = TranscriptionError.closed(TranscriptionError.transportDisconnectedMessage)
    defer {
        watchdog.cancel()
        transport.sending.release()
        transport.incoming.continuation.finish()
        client.channel.continuation.finish()
    }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .grok, values: ["apiKey": "fixture"]))
        let appending = Task { try await service.appendAudio(PCMFrame(samples: [1, -1])) }
        defer {
            appending.cancel()
            transport.sending.release()
        }
        await transport.sending.waitUntilEntered()
        // No reader failure was injected: this is a genuine write failure.
        transport.sending.release()
        await #expect(throws: failure) { try await appending.value }
        #expect(!appending.isCancelled)
        #expect(await service.terminalOutcome == .failed(failure))
        await #expect(throws: failure) { try await client.forwardQueuedEvents() }
        #expect(client.forwarded.get() == [.error(failure)])
        var seen: [PushToTalkState] = []
        for _ in 0..<4 {
            if let state = await states.next() { seen.append(state) }
        }
        #expect(seen == [.idle, .recording(level: 0), .error(failure.message), .idle])
        #expect(await service.finish() == .failed(failure))
        #expect(await service.requiresRestart == false)
        #expect(client.endings.get() == 0)
        #expect(transport.closes.get() > 0)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test(arguments: QueuedProviderFailure.allCases, DeliveryTeardown.allCases)
private func queuedProviderTerminalWinsDuringTheEndMarkerWrite(
    failure: QueuedProviderFailure, teardown: DeliveryTeardown
) async throws {
    let transport = HeldDeliveryTransport(teardown: teardown)
    let watchdog = transport.sending.watchdog()
    let client = GatedProviderDeliveryClient(transport: transport)
    let service = TranscriptionService(client: client)
    defer {
        watchdog.cancel()
        transport.sending.release()
        transport.incoming.continuation.finish()
        client.channel.continuation.finish()
    }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .grok, values: ["apiKey": "fixture"]))
        let finishing = Task { await service.finish() }
        defer {
            finishing.cancel()
            transport.sending.release()
        }
        await transport.sending.waitUntilEntered()
        transport.publish(failure)
        var cancelled = transport.writeCancelled.stream.makeAsyncIterator()
        try #require(await cancelled.next() != nil)
        #expect(client.forwarded.get().isEmpty)
        #expect(await service.terminalOutcome == nil)
        transport.sending.release()
        #expect(await finishing.value == .failed(failure.error))
        #expect(await service.terminalOutcome == .failed(failure.error))
        #expect(await service.requiresRestart == false)
        #expect(client.endings.get() == 1)
        await #expect(throws: failure.error) { try await client.forwardQueuedEvents() }
        #expect(client.forwarded.get() == [.error(failure.error)])
        var seen: [PushToTalkState] = []
        for _ in 0..<4 { if let state = await states.next() { seen.append(state) } }
        #expect(seen == [.idle, .recording(level: 0), .error(failure.error.message), .idle])
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}
