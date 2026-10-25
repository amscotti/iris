import Foundation
import IrisCore
import os

/// WebSocket transport behind the injected byte-stream seam.
///
/// Providers explicitly distinguish text control messages from binary audio.
/// No framing is inferred from payload bytes. Single-owner use by one client,
/// like every transport behind this seam. One instance serves one press: the
/// press factory builds a fresh transport per utterance, so a closed session
/// is never reused.
public final class URLSessionWebSocketTransport: ByteStream, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let headers: [String: String]
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "transport")
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(url: URL, session: URLSession = .shared, headers: [String: String] = [:]) {
        self.url = url
        self.session = session
        self.headers = headers
    }

    deinit {
        let (active, worker) = lock.withLock { () -> (URLSessionWebSocketTask?, Task<Void, Never>?) in
            let active = task
            let worker = receiveTask
            task = nil
            receiveTask = nil
            return (active, worker)
        }
        worker?.cancel()
        active?.cancel(with: .normalClosure, reason: nil)
    }

    /// Handshake request. Extra headers (Grok's Bearer token) ride here;
    /// Meta leaves `headers` empty and puts the key in the JSON body.
    nonisolated static func handshakeRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// An Authorization header whose key carries header delimiters would be
    /// dropped entirely by CFNetwork, silently sending an unauthenticated
    /// upgrade; refuse it before the socket is built. nil when acceptable.
    nonisolated static func authorizationHeaderFailure(headers: [String: String]) -> TranscriptionError? {
        guard let header = headers["Authorization"] else { return nil }
        let key = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
        guard TranscriptionError.apiKeyContainsInvalidCharacters(key) else { return nil }
        return TranscriptionError.auth(TranscriptionError.invalidAPIKeyCharactersMessage)
    }

    public func connect() async throws {
        try Task.checkCancellation()
        guard url.scheme?.lowercased() == "wss" else {
            throw TranscriptionError(
                kind: .invalidState, message: "Speech connections must use wss.")
        }
        // Generation guard: concurrent connects are misuse (single-owner,
        // serial use), but never leak a resumed socket. Only the latest
        // generation creates a task; superseded generations bail out.
        let mine = lock.withLock {
            generation &+= 1
            return generation
        }
        await close()
        try Task.checkCancellation()
        guard lock.withLock({ generation == mine }) else { throw CancellationError() }
        if let failure = Self.authorizationHeaderFailure(headers: headers) { throw failure }
        let request = Self.handshakeRequest(url: url, headers: headers)
        let created = session.webSocketTask(with: request)
        var superseded = false
        var displaced: URLSessionWebSocketTask?
        lock.withLock {
            if generation != mine {
                superseded = true
            } else {
                displaced = task
                task = created
            }
        }
        if superseded {
            created.cancel()
            throw CancellationError()
        }
        displaced?.cancel(with: .normalClosure, reason: nil)
        created.resume()
        let host = self.url.host ?? "?"
        let path = self.url.path
        let authed = headers["Authorization"] != nil
        logger.info(
            "Transport opening \(host, privacy: .public)\(path, privacy: .public) (upgrade authorization header \(authed ? "set" : "not used", privacy: .public))."
        )
    }

    public func write(_ message: TransportMessage) async throws {
        guard let active = lock.withLock({ task }) else {
            throw TranscriptionError(kind: .invalidState, message: "WebSocket write before connect.")
        }
        switch message {
        case .text(let text):
            try await active.send(.string(text))
        case .binary(let data):
            try await active.send(.data(data))
        }
    }

    public func close() async {
        let (active, worker) = lock.withLock { () -> (URLSessionWebSocketTask?, Task<Void, Never>?) in
            let active = task
            let worker = receiveTask
            task = nil
            receiveTask = nil
            return (active, worker)
        }
        worker?.cancel()
        guard active != nil || worker != nil else { return }
        let host = self.url.host ?? "?"
        let path = self.url.path
        logger.info("Transport closed for \(host, privacy: .public)\(path, privacy: .public).")
        active?.cancel(with: .normalClosure, reason: nil)
        await worker?.value
    }

    public func messages() -> AsyncThrowingStream<TransportMessage, Error> {
        guard let active = lock.withLock({ task }) else {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let worker = MessageReceiveLoop.start(continuation: continuation) {
                do {
                    switch try await active.receive() {
                    case .string(let text):
                        return .text(text)
                    case .data(let bytes):
                        return .binary(bytes)
                    @unknown default:
                        return nil
                    }
                } catch {
                    throw Self.receiveFailure(
                        error, statusCode: (active.response as? HTTPURLResponse)?.statusCode,
                        closeCode: active.closeCode.rawValue)
                }
            }
            // Single-consumer contract, enforced: a second subscription
            // cancels the orphaned loop instead of splitting frames.
            let previous = self.lock.withLock { () -> Task<Void, Never>? in
                guard self.task === active else { return worker }
                let old = self.receiveTask
                self.receiveTask = worker
                return old
            }
            previous?.cancel()
        }
    }

    /// A failed WebSocket upgrade may only surface as a generic URL error:
    /// on a failed upgrade `response` is typically nil, so the HTTP status
    /// is recovered from the NSError code, an embedded HTTP response in
    /// `userInfo`, or status/auth substrings in the description.
    nonisolated static func receiveFailure(_ error: Error, statusCode: Int?, closeCode: Int? = nil) -> Error {
        if let failure = error as? TranscriptionError { return failure }
        if let mapped = closeCodeError(closeCode) { return mapped }
        let resolved = statusCode ?? Self.httpStatus(in: error)
        switch resolved {
        case 401, 403:
            return TranscriptionError.auth(TranscriptionError.genericAuthMessage)
        case 429:
            return TranscriptionError(kind: .rateLimited, message: "Provider usage limit reached. Check your quota.")
        default:
            break
        }
        // Deterministic domain/code mappings outrank text heuristics: an
        // ordinary disconnect classifies as such even when the failing URL
        // or description happens to carry auth-like digit runs.
        if let mapped = TranscriptionError.classifiedSocketError(error, closeCode: closeCode) { return mapped }
        let code = (error as NSError).code
        if code == 401 || code == 403 {
            return TranscriptionError.auth(TranscriptionError.genericAuthMessage)
        }
        if let mapped = Self.messageHeuristicError(text: (error as NSError).localizedDescription) { return mapped }
        return error
    }

    /// Auth/rate-limit phrases in a failure description, for upgrades that
    /// never produced an HTTP status.
    nonisolated static func messageHeuristicError(text: String) -> TranscriptionError? {
        TranscriptionError.classifiedTransportError(in: text)
    }

    /// A server close carries its reason in the close code, which the
    /// generic socket error does not mention. Meta documents 1013 (rate
    /// limited), 1008 (invalid request or pacing policy), and 1011
    /// (backend failure or session limit).
    nonisolated static func closeCodeError(_ closeCode: Int?) -> TranscriptionError? {
        switch closeCode {
        case 1013:
            return TranscriptionError(
                kind: .rateLimited, message: "Provider usage limit reached. Check your quota.", closeCode: closeCode)
        case 1008:
            return TranscriptionError(
                kind: .invalidState, message: "Speech request was rejected. Check provider settings and try again.",
                closeCode: closeCode)
        case 1011:
            return TranscriptionError(
                kind: .streamLimit, message: "Speech session ended on the server. Try again.", closeCode: closeCode)
        default:
            return nil
        }
    }
    nonisolated static let posixCloseCodes: Set<Int> = TranscriptionError.posixCloseCodes

    nonisolated private static func httpStatus(in error: Error) -> Int? {
        for value in (error as NSError).userInfo.values {
            if let response = value as? HTTPURLResponse { return response.statusCode }
        }
        return nil
    }

}

/// Pulls frames until cancelled. The worker is cancelled when the stream
/// consumer goes away or `close()` runs, so a dropped iterator cannot leak
/// a receive loop on the shared URLSession.
enum MessageReceiveLoop {
    static func start(
        continuation: AsyncThrowingStream<TransportMessage, Error>.Continuation,
        receive: @escaping @Sendable () async throws -> TransportMessage?
    ) -> Task<Void, Never> {
        let worker = Task {
            do {
                while !Task.isCancelled {
                    guard let message = try await receive() else { break }
                    if case .dropped = continuation.yield(message) {
                        throw TranscriptionError(
                            kind: .network, message: "Speech transport buffer overflow; please retry.")
                    }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
        continuation.onTermination = { _ in worker.cancel() }
        return worker
    }
}
