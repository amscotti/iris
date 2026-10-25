import Foundation
import IrisCore
import os

/// HTTP executor for the registered provider's rewrite adapter.
///
/// The endpoint, key, model, and reasoning come from one immutable provider
/// configuration. Prompts supply text only. Any failure — missing key, timeout, HTTP error,
/// decode failure, or an empty reply — returns nil so the caller keeps the
/// text as it stood. Uses URLSession only, with no extra dependencies.
public final class RewriteChatClient: Sendable {
    /// Per-request idle timeout. A non-streaming reply sends nothing until
    /// generation ends, so this matches the wall-clock deadline instead of
    /// cutting off a high-reasoning rewrite at 30 seconds.
    public static let defaultTimeoutSeconds: TimeInterval = 60
    /// Largest rewrite response body accepted. Anything larger returns nil
    /// so the caller keeps the original text.
    public static let maxResponseBytes = 256 * 1024
    /// Wall-clock bound on one rewrite. `URLRequest.timeoutInterval` only
    /// limits *idle* time, so a trickling server could otherwise hold the
    /// take in "Rewriting…" (blocking new presses) indefinitely.
    public static let deadlineSeconds: TimeInterval = 60

    private static let logger = Logger(subsystem: AppIdentity.identifier, category: "rewrite")

    private let session: URLSession
    private let timeoutSeconds: TimeInterval
    private let deadlineSeconds: TimeInterval
    private let configuration: ProviderConfiguration
    private let rewriter: (any RewriteAdapter)?

    /// - Parameters:
    ///   - session: URLSession used for the POST. Injectable for tests.
    ///   - timeoutSeconds: Per-request idle timeout. Defaults to 60 seconds.
    ///   - configuration: Snapshot for the active provider. Unknown providers
    ///     and missing keys make no request; there is no fallback endpoint.
    public init(
        configuration: ProviderConfiguration,
        registry: ProviderRegistry,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = RewriteChatClient.defaultTimeoutSeconds,
        deadlineSeconds: TimeInterval = RewriteChatClient.deadlineSeconds
    ) {
        self.session = session
        self.timeoutSeconds =
            timeoutSeconds.isFinite && timeoutSeconds > 0
            ? timeoutSeconds : Self.defaultTimeoutSeconds
        self.deadlineSeconds =
            deadlineSeconds.isFinite && deadlineSeconds > 0
            ? deadlineSeconds : Self.deadlineSeconds
        self.configuration = configuration
        self.rewriter = registry.rewriter(for: configuration.provider)
    }

    /// Rewrites `text` with `prompt`, or returns nil on any failure.
    public func rewrite(text: String, prompt: PromptDefinition) async -> String? {
        if Task.isCancelled { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let rewriter, let wire = rewriter.makeRequest(text: text, prompt: prompt, config: configuration) else {
            return nil
        }
        // The adapter contract requires https whenever the request carries
        // credentials; re-check here since adapters only describe the request.
        guard wire.url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: wire.url, timeoutInterval: timeoutSeconds)
        request.httpMethod = wire.method
        for (field, value) in wire.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = wire.body
        let fetch = Task { [session] in try await Self.fetchCapped(request, session: session) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await AsyncDeadline.run(seconds: deadlineSeconds) {
                try await fetch.value
            }
        } catch is CancellationError {
            fetch.cancel()
            Self.logFailure("cancelled")
            return nil
        } catch is ResponseTooLarge {
            Self.logFailure("response over size cap")
            return nil
        } catch {
            fetch.cancel()
            let reason =
                (error as? TranscriptionError).map { $0.kind.rawValue }
                ?? (error as? URLError).map { $0.errorCode.description }
                ?? "transport"
            Self.logFailure("transport (\(reason))")
            return nil
        }
        if Task.isCancelled { return nil }
        return validatedText(from: response, data: data)
    }

    /// Thrown once a reply is known to exceed `maxResponseBytes`.
    private struct ResponseTooLarge: Error {}

    /// Streams the body so `maxResponseBytes` bounds memory during the
    /// download: a declared oversized length is refused before reading, and
    /// an undeclared one is cut off as soon as it crosses the cap.
    private static func fetchCapped(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maxResponseBytes) else {
            bytes.task.cancel()
            throw ResponseTooLarge()
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes {
                bytes.task.cancel()
                throw ResponseTooLarge()
            }
        }
        return (data, response)
    }

    /// Response checks that map onto nil fail-open: wrong status or an
    /// unusable reply keep the original transcript. Size is enforced while
    /// streaming (`fetchCapped`).
    private func validatedText(from response: URLResponse, data: Data) -> String? {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.logFailure("http status \(status)")
            return nil
        }
        guard let rewriter,
            let text = rewriter.responseText(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            Self.logFailure("no usable reply body")
            return nil
        }
        return text
    }

    /// Failure categories only — never the transcript, prompt, or key.
    private static func logFailure(_ category: String) {
        logger.notice("Rewrite failed, keeping the original text: \(category, privacy: .public).")
    }
}
