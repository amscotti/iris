import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

@Test @MainActor func storedKeyIsNotAValidatedConnection() async {
    let connections = ProviderConnections(probe: { _ in })
    #expect(connections.state(for: "Grok") == .notChecked)
    await connections.check(ProviderConfiguration(provider: .grok, values: ["apiKey": "test"]))
    #expect(connections.state(for: "Grok") == .connected)
    #expect(connections.state(for: "Meta") == .notChecked)
    connections.invalidate("Grok")
    #expect(connections.state(for: "Grok") == .notChecked)
}

@Test @MainActor func connectionCheckReportsRejectedCredentials() async {
    let connections = ProviderConnections(probe: { _ in throw TranscriptionError.auth("rejected") })
    await connections.check(ProviderConfiguration(provider: .grok, values: ["apiKey": "test"]))
    guard case .failed(let message) = connections.state(for: "Grok") else {
        Issue.record("A rejected key must not display as connected.")
        return
    }
    #expect(message.contains("API key was rejected"))
}

@Test @MainActor func missingKeyNeverStartsAConnectionCheck() async {
    let connections = ProviderConnections(probe: { _ in Issue.record("Must not make a request without a key") })
    await connections.check(ProviderConfiguration(provider: .grok))
    #expect(connections.state(for: "Grok") == .failed("Save an API key before testing the connection."))
}

private final class ProbeCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.withLock { stored = true } }
    var value: Bool { lock.withLock { stored } }
}

@Test @MainActor func cancellingCallerCancelsOwnedConnectionProbe() async {
    let cancelled = ProbeCancellationFlag()
    let connections = ProviderConnections(probe: { _ in
        await withTaskCancellationHandler {
            try? await Task.sleep(for: .seconds(1))
        } onCancel: {
            cancelled.set()
        }
        try Task.checkCancellation()
    })
    let checking = Task { @MainActor in
        await connections.check(ProviderConfiguration(provider: .grok, values: ["apiKey": "test"]))
    }
    try? await Task.sleep(for: .milliseconds(50))
    checking.cancel()
    await checking.value
    #expect(cancelled.value)
    #expect(connections.state(for: "Grok") == .notChecked)
}

@Test func webSocketUpgradeFailurePreservesAuthenticationAndQuotaErrors() {
    let generic = URLError(.badServerResponse)
    let auth = URLSessionWebSocketTransport.receiveFailure(generic, statusCode: 401) as? TranscriptionError
    let quota = URLSessionWebSocketTransport.receiveFailure(generic, statusCode: 429) as? TranscriptionError
    #expect(auth?.kind == .authentication)
    #expect(quota?.kind == .rateLimited)
}

@Test @MainActor func keylessProviderSkipsTheAPIKeyGuard() async {
    let connections = ProviderConnections(probe: { _ in }, requiresAPIKey: { _ in false })
    await connections.check(ProviderConfiguration(provider: .mock, values: [:]))
    #expect(connections.state(for: "mock") == .connected)
}

@Test @MainActor func keyedProviderStillFailsWithoutAKey() async {
    let connections = ProviderConnections(probe: { _ in Issue.record("Must not probe without a key") })
    await connections.check(ProviderConfiguration(provider: .mock, values: [:]))
    guard case .failed(let message) = connections.state(for: "mock") else {
        Issue.record("Expected a missing-key failure")
        return
    }
    #expect(message.contains("API key"))
}

/// Client whose `cancel` blocks for a fixed duration before returning, so a
/// probe shutdown can be timed against the service's cleanup budget.
private struct SlowCancelClient: TranscriptionClient, Sendable {
    let cancelDuration: Double
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)

    init(cancelDuration: Double) { self.cancelDuration = cancelDuration }

    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws {}
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws { channel.continuation.finish() }
    func cancel() async {
        channel.continuation.finish(throwing: CancellationError())
        try? await Task.sleep(for: .seconds(cancelDuration))
    }
}

@Test @MainActor func probeShutdownThatFitsTheBudgetStaysConnected() async {
    // A cancel completing just under the inner shutdown budget is a clean
    // shutdown, not a timeout: the probe must keep its headroom over the
    // service's own deadline instead of racing it.
    let connections = ProviderConnections(probe: { config in
        try await SpeechConnectionProbe.check(
            config,
            makeService: { _ in
                TranscriptionService(client: SlowCancelClient(cancelDuration: 0.4), shutdownTimeout: 0.5)
            })
    })
    await connections.check(ProviderConfiguration(provider: .grok, values: ["apiKey": "k"]))
    #expect(connections.state(for: "Grok") == .connected)
}

@Test @MainActor func probeRestartVerdictKeepsItsSentence() async {
    // A shutdown that genuinely exceeds the budget reports the restart
    // requirement verbatim; the per-kind generic copy must not swallow it.
    let connections = ProviderConnections(probe: { config in
        try await SpeechConnectionProbe.check(
            config,
            makeService: { _ in
                TranscriptionService(client: SlowCancelClient(cancelDuration: 10), shutdownTimeout: 0.05)
            })
    })
    await connections.check(ProviderConfiguration(provider: .grok, values: ["apiKey": "k"]))
    guard case .failed(let message) = connections.state(for: "Grok") else {
        Issue.record("Expected a restart failure")
        return
    }
    #expect(message == TranscriptionService.restartMessage)
}
