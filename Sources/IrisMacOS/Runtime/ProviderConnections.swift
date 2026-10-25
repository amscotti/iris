import Foundation
import IrisCore
import Observation

public enum ProviderConnectionState: Equatable, Sendable {
    case notChecked
    case checking
    case connected
    case failed(String)
}

/// Explicit, per-provider checks. A stored key is not proof that a service
/// accepts it. Only a successful speech-session handshake earns Connected.
@MainActor
@Observable
public final class ProviderConnections {
    public typealias Check = @Sendable (ProviderConfiguration) async throws -> Void
    /// True when the named provider needs an `apiKey` before a connection
    /// test can run. Keyless providers (no secret fields in their
    /// descriptor) skip the guard so they remain testable.
    public typealias RequiresAPIKey = @Sendable (ProviderConfiguration) -> Bool

    public private(set) var states: [String: ProviderConnectionState] = [:]
    private let probe: Check
    private let requiresAPIKey: RequiresAPIKey
    @ObservationIgnored private var revisions: [String: Int] = [:]
    /// The actual probe task per provider, so `invalidate` can cancel the
    /// provider session itself rather than a detached wrapper.
    @ObservationIgnored private var inFlight: [String: Task<Void, Error>] = [:]

    public init(
        probe: @escaping Check,
        requiresAPIKey: @escaping RequiresAPIKey = { _ in true }
    ) {
        self.probe = probe
        self.requiresAPIKey = requiresAPIKey
    }

    public func state(for provider: String) -> ProviderConnectionState {
        states[provider] ?? .notChecked
    }

    public func invalidate(_ provider: String) {
        revisions[provider, default: 0] += 1
        // Cancel the in-flight probe so invalidation cannot leave two
        // concurrent provider sessions racing to publish state.
        inFlight.removeValue(forKey: provider)?.cancel()
        states[provider] = .notChecked
    }

    public func check(_ config: ProviderConfiguration) async {
        let provider = config.provider.name
        guard state(for: provider) != .checking else { return }
        if config.apiKey == nil, requiresAPIKey(config) {
            states[provider] = .failed("Save an API key before testing the connection.")
            return
        }
        let revision = revisions[provider, default: 0]
        states[provider] = .checking
        let check = Task { try await probe(config) }
        inFlight[provider] = check
        defer {
            // Only clear our own registration: an invalidate (revision
            // bump) already removed it, and a newer check may own the slot.
            if revisions[provider, default: 0] == revision { inFlight[provider] = nil }
        }
        do {
            try await withTaskCancellationHandler {
                try await check.value
            } onCancel: {
                check.cancel()
            }
            guard revisions[provider, default: 0] == revision else { return }
            states[provider] = .connected
        } catch {
            guard revisions[provider, default: 0] == revision else { return }
            if error is CancellationError {
                states[provider] = .notChecked
            } else {
                states[provider] = .failed(Self.message(for: error))
            }
        }
    }

    static func message(for error: Error) -> String {
        guard let failure = error as? TranscriptionError else {
            return "Couldn’t connect. Check your internet connection and try again."
        }
        // A specific verdict sentence outranks the per-kind generic copy:
        // the restart requirement or invalid-character guidance must reach the user verbatim.
        if failure.message == TranscriptionService.restartMessage
            || failure.message == TranscriptionError.invalidAPIKeyCharactersMessage
        {
            return failure.message
        }
        switch failure.kind {
        case .authentication: return "The API key was rejected. Check the key and your provider account’s access."
        case .rateLimited: return "The provider’s usage limit was reached. Check your quota, then try again."
        case .timeout: return "The provider didn’t respond in time. Try again in a moment."
        default: return "Couldn’t open a speech session. Check your connection and provider settings, then try again."
        }
    }
}

public enum SpeechConnectionProbe {
    /// Headroom over the service's inner shutdown budget (2 s): the probe's
    /// own deadline must never fire before a cancel that legitimately uses
    /// its full budget has had its verdict rendered.
    private static let shutdownHeadroomSeconds = 3.0

    /// Uses exactly the same transport and handshake as dictation, but never
    /// starts capture or sends microphone audio. The socket is always closed.
    public static func check(_ config: ProviderConfiguration, makeService: DictationOrchestrator.ServiceFactory)
        async throws
    {
        let service = makeService(config)
        do {
            try await service.start(config: config)
        } catch {
            await service.cancel()
            throw error
        }
        let verdict: SessionShutdown
        do {
            verdict = try await AsyncDeadline.run(
                seconds: Self.shutdownHeadroomSeconds, ignoringCancellation: true
            ) {
                await service.cancel()
            }
        } catch {
            verdict = .timedOut
        }
        guard verdict == .clean else {
            throw TranscriptionError(kind: .timeout, message: TranscriptionService.restartMessage)
        }
    }
}
