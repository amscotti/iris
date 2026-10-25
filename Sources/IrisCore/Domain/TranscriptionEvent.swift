import Foundation

/// Categorized failure for a transcription attempt.
///
/// The category drives recovery: authentication failures surface guidance and
/// never retry on their own, while transport failures allow a single retry on
/// the next key press (never a mid-press loop).
public struct TranscriptionError: Error, Sendable, Equatable, Hashable, CustomStringConvertible, LocalizedError {
    public enum Kind: String, Sendable, Equatable, Hashable, Codable {
        case authentication
        case network
        case rateLimited
        case streamLimit
        case serverClosed
        case timeout
        case invalidState
        case decoding
        case unknown
    }

    public var kind: Kind
    public var message: String
    public var closeCode: Int?

    public init(kind: Kind, message: String, closeCode: Int? = nil) {
        self.kind = kind
        self.message = message
        self.closeCode = closeCode
    }

    /// Authentication failures must not retry; they point at Settings instead.
    public var isAuthFailure: Bool { kind == .authentication }

    /// Only WebSocket normal closure and going-away complete a close-delimited
    /// session. Explicitly modeled closes may omit metadata and retain the
    /// legacy clean-close behavior; an abnormal supplied code never does.
    public var isNormalClosure: Bool {
        kind == .serverClosed && (closeCode == nil || closeCode == 1000 || closeCode == 1001)
    }

    /// Close metadata is transport diagnostics, not a new error identity.
    /// Preserve the original kind/message value semantics for event matching,
    /// deduplication, and clients that compare categorized failures.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(message)
    }

    /// Human-readable message only. The category stays in `kind` so logs
    /// that need it can render `"[\(kind)] \(message)"` themselves.
    public var description: String { message }

    /// `error.localizedDescription` must surface the actionable message, not
    /// the generic NSError wrapper ("The operation couldn't be completed").
    public var errorDescription: String? { message }

    public static func auth(_ message: String) -> TranscriptionError {
        TranscriptionError(kind: .authentication, message: message)
    }

    public static func closed(_ message: String, closeCode: Int? = nil) -> TranscriptionError {
        TranscriptionError(kind: .serverClosed, message: message, closeCode: closeCode)
    }
}

/// Provider-neutral transcription events.
///
/// Provider adapters map their raw wire events onto these cases so the
/// orchestrator and UI never see provider-specific shapes.
public enum TranscriptionEvent: Sendable, Equatable, Hashable {
    /// A mid-stream hypothesis. Replaces (never appends to) the previous one.
    case partial(String)
    /// The completed transcript for the utterance. Insert at most once.
    case final(String)
    /// Speech onset was detected.
    case speechStarted
    /// A turn boundary. `transcript` is the text of that turn when the
    /// server includes it; otherwise empty (push-to-talk boundaries).
    case speechComplete(turnId: String, transcript: String)
    /// A categorized failure.
    case error(TranscriptionError)

    /// Push-to-talk completion only: true for `.final`, false otherwise.
    ///
    /// Endpointing-style sessions (`TranscriptCompletionPolicy.turnComplete`)
    /// complete on `.speechComplete` instead, so code that must handle both
    /// policies should use `isCompletion(under:)` rather than this flag.
    public var isFinal: Bool {
        if case .final = self { return true }
        return false
    }

    /// Whether this event completes an utterance under the given policy:
    /// `.final` under `.finalEvent`, `.speechComplete` under `.turnComplete`.
    public func isCompletion(under policy: TranscriptCompletionPolicy) -> Bool {
        switch (self, policy) {
        case (.final, .finalEvent): return true
        case (.speechComplete, .turnComplete): return true
        default: return false
        }
    }

    /// The displayable text, when the event carries any.
    ///
    /// An empty-turn `.speechComplete(turnId:transcript: "")` yields `nil`,
    /// exactly like the textless `.speechStarted`/`.error` cases: a `nil`
    /// result means "no text to display", never "empty turn vs. no event".
    /// Callers that must distinguish an empty turn need to match on
    /// `.speechComplete` directly.
    public var text: String? {
        switch self {
        case .partial(let text): return text
        case .final(let text): return text
        case .speechComplete(_, let transcript):
            return transcript.isEmpty ? nil : transcript
        case .speechStarted, .error: return nil
        }
    }
}

/// Which domain event completes an utterance.
///
/// Push-to-talk completes on a final transcript event; endpointing-style
/// sessions complete on a per-turn boundary event instead.
public enum TranscriptCompletionPolicy: String, Sendable, Equatable, Hashable, Codable {
    case finalEvent
    case turnComplete
}

extension TranscriptionError {
    /// Shared auth sentence from transport classification. A provider may
    /// replace this sentence with its own. A more specific auth message stays.
    public static let genericAuthMessage = "API key rejected. Check Settings → Providers."

    /// Rejection copy for a stored key containing characters that would
    /// split or inject HTTP headers.
    public static let invalidAPIKeyCharactersMessage =
        "The API key contains invalid characters. Enter the key again in Settings → Providers."

    /// True for a key that must never enter an HTTP header: interior
    /// whitespace, newlines, or control characters would be dropped or
    /// split by the network stack, silently downgrading the request to
    /// unauthenticated. Mirrors the rewrite path's rule.
    public static func apiKeyContainsInvalidCharacters(_ key: String) -> Bool {
        key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) != nil
    }

    /// Friendly copy for a transport that died mid-session.
    public static let transportDisconnectedMessage = "The speech service disconnected before finishing. Try again."

    /// POSIX errnos (ENOTCONN, ECONNRESET, EPIPE) that a server-initiated
    /// WebSocket close surfaces as on Apple platforms, not as -1005.
    public static let posixCloseCodes: Set<Int> = [57, 54, 32]

    /// Deterministic NSError classification shared by the transport's read
    /// and write paths. Returns nil when no domain/code mapping applies.
    public static func classifiedSocketError(_ error: Error, closeCode: Int? = nil) -> TranscriptionError? {
        if let failure = error as? TranscriptionError { return failure }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return TranscriptionError(
                    kind: .timeout, message: "The provider didn’t respond in time. Try again.", closeCode: closeCode)
            case NSURLErrorNetworkConnectionLost:
                return closed(transportDisconnectedMessage, closeCode: closeCode)
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, posixCloseCodes.contains(nsError.code) {
            return closed(transportDisconnectedMessage, closeCode: closeCode)
        }
        return nil
    }

    /// Auth and rate-limit phrases in a failure description. The text is
    /// lowercased here; callers may already have lowercased it. Bare status
    /// digits are deliberately not scanned: descriptions and URLs like
    /// "Room 401" must not classify as auth. Explicit status codes are
    /// handled deterministically by the transport instead.
    public static func classifiedTransportError(in text: String) -> TranscriptionError? {
        let lower = text.lowercased()
        if mentionsAuthentication(lower) {
            return .auth(genericAuthMessage)
        }
        if mentionsRateLimit(lower) {
            return TranscriptionError(
                kind: .rateLimited, message: "Provider usage limit reached. Check your quota.")
        }
        return nil
    }

    /// Word-based server-error classification shared by provider wire
    /// protocols; the message itself stays provider-owned. Input is a
    /// lowercased message. nil when no phrase matches.
    public static func classifiedServerPhrase(in lower: String) -> Kind? {
        // Provider codes use snake_case spellings of the same phrases.
        let normalized = lower.replacingOccurrences(of: "_", with: " ")
        if mentionsAuthentication(normalized) { return .authentication }
        if mentionsRateLimit(normalized) { return .rateLimited }
        if normalized.contains("stream limit") || normalized.contains("too many") { return .streamLimit }
        return nil
    }

    /// One auth-phrase table shared by both classification doors, so the
    /// same sentence never classifies differently depending on whether it
    /// arrived in-band (server error event) or on the transport. Input is a
    /// lowercased string.
    package static func mentionsAuthentication(_ lowercased: String) -> Bool {
        [
            "auth", "api key", "api_key", "invalid-key", "invalid_key", "invalid token", "invalid access token",
            "invalid credential",
        ].contains { lowercased.contains($0) }
    }

    /// Whether a lowercased provider message reports a rate or quota limit.
    /// Deliberately narrower than "rate", which also appears in "sample rate".
    package static func mentionsRateLimit(_ lowercased: String) -> Bool {
        ["rate limit", "rate_limit", "rate-limit", "rate exceeded", "ratelimit", "too many requests", "quota"]
            .contains { lowercased.contains($0) }
    }
}
