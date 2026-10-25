import Foundation
import IrisProviders
import Testing

@testable import IrisCore

private enum CancelledDeliveryReply: String, CaseIterable, Sendable {
    case taskCancellation, urlCancellation

    var error: any Error {
        switch self {
        case .taskCancellation: return CancellationError()
        case .urlCancellation: return URLError(.cancelled)
        }
    }
}

private final class CancelledDeliveryClient: TranscriptionClient, Sendable {
    let sending = ManualGate()
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    let queued = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    let forwarded = TestValue<[TranscriptionEvent]>([])
    let cancellations = TestValue(0)
    let endings = TestValue(0)
    let reply: CancelledDeliveryReply
    let finishStream: Bool

    init(reply: CancelledDeliveryReply, finishStream: Bool = false) {
        self.reply = reply
        self.finishStream = finishStream
    }
    func start(config: ProviderConfiguration) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func sendAudio(_ frame: PCMFrame) async throws {
        await sending.wait()
        if finishStream { channel.continuation.finish(throwing: reply.error) }
        throw reply.error
    }
    func endAudio() async throws { endings.update { $0 += 1 } }
    func cancel() async {
        cancellations.update { $0 += 1 }
        channel.continuation.finish(throwing: CancellationError())
        queued.continuation.finish(throwing: CancellationError())
    }
    func queueTerminal(_ failure: TranscriptionError) {
        queued.continuation.yield(.error(failure))
        queued.continuation.finish(throwing: failure)
    }
    func forwardQueuedTerminal() async throws {
        do {
            for try await event in queued.stream {
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

@Test(
    arguments: [
        TranscriptionError.auth("queued authentication failure"),
        TranscriptionError(kind: .rateLimited, message: "queued rate limit failure"),
        TranscriptionError.closed("queued server close"),
    ], CancelledDeliveryReply.allCases)
private func aCancelledSendReplyDoesNotDiscardAnUnreadTerminal(
    failure: TranscriptionError, reply: CancelledDeliveryReply
) async throws {
    let client = CancelledDeliveryClient(reply: reply)
    let watchdog = client.sending.watchdog()
    let service = TranscriptionService(client: client, shutdownTimeout: 5)
    defer {
        watchdog.cancel()
        client.sending.release()
        client.channel.continuation.finish()
        client.queued.continuation.finish()
    }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .mock))
        let appending = Task { try await service.appendAudio(PCMFrame(samples: [1, -1])) }
        defer {
            appending.cancel()
            client.sending.release()
        }
        await client.sending.waitUntilEntered()
        client.queueTerminal(failure)
        client.sending.release()
        // Event delivery is held until after this reply. Joining the reader
        // inside appendAudio would deadlock this ordering and hit the deadline.
        await #expect(throws: CancellationError.self) { try await appending.value }
        #expect(!appending.isCancelled)
        #expect(client.forwarded.get().isEmpty)
        #expect(client.cancellations.get() == 0)
        #expect(await service.terminalOutcome == nil)
        await #expect(throws: failure) { try await client.forwardQueuedTerminal() }
        #expect(client.forwarded.get() == [.error(failure)])

        var seen: [PushToTalkState] = []
        for _ in 0..<4 {
            if let state = await states.next() { seen.append(state) }
        }
        #expect(seen == [.idle, .recording(level: 0), .error(failure.message), .idle])
        #expect(await service.terminalOutcome == .failed(failure))
        #expect(await service.finish() == .failed(failure))
        #expect(await service.requiresRestart == false)
        #expect(await service.lastFinal == nil)
        #expect(client.endings.get() == 0)
        #expect(client.cancellations.get() == 1)
        #expect(await service.cancel() == .clean)
        #expect(await states.next() == .idle)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test(arguments: CancelledDeliveryReply.allCases, [false, true])
private func aCancelledSendWithoutATerminalCannotRemainRecording(
    reply: CancelledDeliveryReply, finishStream: Bool
) async throws {
    let client = CancelledDeliveryClient(reply: reply, finishStream: finishStream)
    let watchdog = client.sending.watchdog()
    let service = TranscriptionService(client: client, shutdownTimeout: 0.2)
    let failure = TranscriptionError(
        kind: .network, message: "Audio delivery was cancelled before the speech service finished. Try again.")
    defer {
        watchdog.cancel()
        client.sending.release()
        client.channel.continuation.finish()
        client.queued.continuation.finish()
    }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .mock))
        let appending = Task { try await service.appendAudio(PCMFrame(samples: [1, -1])) }
        defer {
            appending.cancel()
            client.sending.release()
        }
        await client.sending.waitUntilEntered()
        client.sending.release()
        await #expect(throws: CancellationError.self) { try await appending.value }
        #expect(!appending.isCancelled)
        // finish joins the bounded settlement, not endAudio on the broken
        // recording. Neither an open stream nor cancellation-only EOF can hang.
        #expect(await service.finish() == .failed(failure))
        #expect(await service.terminalOutcome == .failed(failure))
        #expect(await service.currentState == .idle)
        #expect(await service.requiresRestart == false)
        #expect(await service.lastFinal == nil)
        #expect(client.endings.get() == 0)
        #expect(client.cancellations.get() == 1)
        var seen: [PushToTalkState] = []
        for _ in 0..<4 {
            if let state = await states.next() { seen.append(state) }
        }
        #expect(seen == [.idle, .recording(level: 0), .error(failure.message), .idle])
        #expect(await service.cancel() == .clean)
        #expect(await states.next() == .idle)
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test(arguments: [false, true])
func callerCancellationRetiresPendingDeliverySettlement(finishing: Bool) async throws {
    let client = CancelledDeliveryClient(reply: .taskCancellation)
    let watchdog = client.sending.watchdog()
    let service = TranscriptionService(client: client, shutdownTimeout: 5)
    defer {
        watchdog.cancel()
        client.sending.release()
        client.channel.continuation.finish()
        client.queued.continuation.finish()
    }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .mock))
        let appending = Task { try await service.appendAudio(PCMFrame(samples: [1, -1])) }
        defer {
            appending.cancel()
            client.sending.release()
        }
        await client.sending.waitUntilEntered()
        client.sending.release()
        await #expect(throws: CancellationError.self) { try await appending.value }
        #expect(await service.terminalOutcome == nil)
        if finishing {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await service.finish()
            }
            defer { cancelled.cancel() }
            let outcome = try await AsyncDeadline.run(seconds: 2) { await cancelled.value }
            #expect(outcome == .cancelled)
        } else {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await service.cancel()
            }
            defer { cancelled.cancel() }
            let shutdown = try await AsyncDeadline.run(seconds: 2) { await cancelled.value }
            #expect(shutdown == .clean)
        }
        #expect(await service.terminalOutcome == .cancelled)
        #expect(await service.currentState == .idle)
        #expect(await service.requiresRestart == false)
        #expect((client.cancellations.get(), client.endings.get()) == (1, 0))
        var seen: [PushToTalkState] = []
        for _ in 0..<3 {
            if let state = await states.next() { seen.append(state) }
        }
        #expect(seen == [.idle, .recording(level: 0), .idle])
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

@Test func aGenuineCategorizedSendFailureStillFailsImmediately() async throws {
    let client = ControlledClient(failSend: true)
    let service = TranscriptionService(client: client)
    let failure = TranscriptionError(kind: .network, message: "audio failure")
    defer { client.channel.continuation.finish() }
    let checking = Task {
        var states = (await service.states()).makeAsyncIterator()
        try await service.start(config: ProviderConfiguration(provider: .mock))
        await #expect(throws: failure) { try await service.appendAudio(PCMFrame(samples: [1, -1])) }
        #expect(await service.terminalOutcome == .failed(failure))
        #expect(await service.currentState == .idle)
        #expect(await service.finish() == .failed(failure))
        #expect(await service.requiresRestart == false)
        var seen: [PushToTalkState] = []
        for _ in 0..<4 {
            if let state = await states.next() { seen.append(state) }
        }
        #expect(seen == [.idle, .recording(level: 0), .error(failure.message), .idle])
    }
    defer { checking.cancel() }
    try await AsyncDeadline.run(seconds: 5) { try await checking.value }
}

private struct CancelledEndMarkerClient: TranscriptionClient {
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    let closesStream: Bool
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        if closesStream { channel.continuation.finish(throwing: CancellationError()) }
        throw URLError(.cancelled)
    }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test(arguments: [false, true])
func cancelledEndMarkerWithoutCallerCancellationHasABoundedFailure(closesStream: Bool) async throws {
    let client = CancelledEndMarkerClient(closesStream: closesStream)
    let service = TranscriptionService(client: client, shutdownTimeout: 0.1)
    defer { client.channel.continuation.finish() }
    try await service.start(config: ProviderConfiguration(provider: .mock))
    let result = try await AsyncDeadline.run(seconds: 5) { await service.finish() }
    guard case .failed(let failure) = result else {
        Issue.record("Transport cancellation must not masquerade as caller cancellation")
        return
    }
    #expect(failure.kind == .network)
    #expect(await service.terminalOutcome == result)
    #expect(await service.currentState == .idle)
    #expect(await service.requiresRestart == false)
}

/// A send that fails instantly while the terminal is still queued behind it
/// on the event stream.
private struct FailingSendClient: TranscriptionClient, Sendable {
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {
        throw TranscriptionError(kind: .network, message: "connection reset")
    }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {}
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

@Test func aQueuedFinalArrivingDuringAFailedSendSettleWins() async throws {
    let client = FailingSendClient()
    let service = TranscriptionService(client: client)
    defer { client.channel.continuation.finish() }
    let appending = Task {
        try await service.start(config: ProviderConfiguration(provider: .mock))
        try await service.appendAudio(PCMFrame(samples: [1, -1]))
    }
    // Let the send failure reach its settlement window with the outcome
    // still undecided, then deliver the queued final.
    try await Task.sleep(nanoseconds: 50_000_000)
    client.channel.continuation.yield(.final("spoken words"))
    _ = try? await AsyncDeadline.run(seconds: 5) { try await appending.value }
    // The terminal that already arrived outranks the teardown error.
    #expect(await service.terminalOutcome == .completed("spoken words"))
}
