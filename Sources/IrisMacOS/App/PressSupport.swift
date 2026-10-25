import AVFoundation
import AppKit
import Foundation
import IrisCore

/// Live permission probes shared by the app graph's authorization port.
/// The runtime rebuilds its gate as the permission snapshot changes, so the
/// live app passes these closures through rather than a gate frozen at launch.
enum LivePermissionProbes {
    static let microphone: @Sendable () -> Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    static let accessibility: @Sendable () -> Bool = { AXIsProcessTrusted() }
    static let image: @Sendable () -> Bool = ApplicationImage.isCurrent
}

/// Composition helpers for provider I/O and the injected per-press gate.
/// The input runtime owns all instances used by a live take.
extension AppComposition {
    /// Freeze the route and key for a whole take, including the later rewrite.
    nonisolated static func makeRewrite(config: ProviderConfiguration, registry: ProviderRegistry) -> PromptRewrite? {
        guard registry.rewriter(for: config.provider) != nil else { return nil }
        let client = RewriteChatClient(configuration: config, registry: registry)
        let settings = RewriteConfiguration(config: config, registry: registry)
        return { text, prompt in
            let started = ContinuousClock.now
            let result = await client.rewrite(text: text, prompt: prompt)
            if let settings {
                PressTimelineLog.rewriteFinished(
                    settings, elapsed: started.duration(to: .now), succeeded: result != nil)
            }
            return result
        }
    }

    /// Factory for the per-press provider client, resolved by persisted
    /// name through the registry — never a hard-coded concrete type. Takes
    /// the registry directly: it is immutable for the app lifetime, while a
    /// box snapshot seeded at composition time would go stale (settings and
    /// secrets load after composition).
    nonisolated static func makeServiceFactory(registry: ProviderRegistry) -> DictationOrchestrator.ServiceFactory {
        { [registry] config in
            let transport = Self.makeTransport(config: config, registry: registry)
            let client =
                registry.makeClient(
                    named: config.provider.name, config: config, transport: transport)
                ?? UnavailableTranscriptionClient()
            return TranscriptionService(
                client: client,
                completion: registry.provider(for: config.provider)?.completionPolicy(for: config) ?? .finalEvent)
        }
    }

    /// Platform transport for the connection supplied by the provider.
    nonisolated static func makeTransport(
        config: ProviderConfiguration, registry: ProviderRegistry
    ) -> any ByteStream {
        if let connection = registry.provider(for: config.provider)?.connection(for: config) {
            return URLSessionWebSocketTransport(url: connection.url, headers: connection.headers)
        }
        return DiscardedTransport()
    }
}
