import Foundation
import IrisCore

/// Session mode for the voice transcribe API.
public enum MetaTranscriptionMode: String, Sendable, Equatable, Hashable, Codable {
    case pushToTalk = "PUSH_TO_TALK"
    case endpointing = "ENDPOINTING"
    case diarization = "DIARIZATION"
}

/// Required audio encoding token. There is no server default: the handshake
/// must always carry one of these strings.
public enum MetaAudioEncoding: String, Sendable, Equatable, Hashable, Codable {
    /// 16 kHz mono Int16 (32,000 B/s, server-resampled).
    case pcm16k = "PCM_16KHZ"
    /// 24 kHz mono Int16 (48,000 B/s, engine-native).
    case pcm24k = "PCM_24KHZ"

    /// Maps a sample rate to its wire token. Unrecognized rates are rejected.
    public init?(sampleRate: Int) {
        switch sampleRate {
        case 16000: self = .pcm16k
        case 24000: self = .pcm24k
        default: return nil
        }
    }

    public var sampleRate: Int {
        switch self {
        case .pcm16k: return 16000
        case .pcm24k: return 24000
        }
    }
}

/// Partial delivery style. Cumulative partials replace the previous text.
public enum MetaPartialMode: String, Sendable, Equatable, Hashable, Codable {
    case cumulative = "CUMULATIVE"
}

/// Validated Muse Voice Transcribe languages, using the names the API
/// expects. An empty value means Auto: omit `languageBias` so the model
/// detects the language itself.
public enum MetaLanguageBias {
    public static let auto = ""

    public static let names: [String] = [
        "Arabic", "Bengali", "Dutch", "English", "French", "German", "Hebrew",
        "Hindi", "Indonesian", "Italian", "Japanese", "Kannada", "Korean",
        "Malay", "Mandarin Chinese", "Marathi", "Polish", "Portuguese",
        "Spanish", "Tagalog", "Tamil", "Telugu", "Thai", "Turkish", "Vietnamese",
    ]

    private static let aliases: [String: String] = [
        "auto": auto,
        "ar": "Arabic", "bn": "Bengali", "nl": "Dutch", "en": "English",
        "eng": "English", "fr": "French", "de": "German", "he": "Hebrew",
        "iw": "Hebrew", "hi": "Hindi", "id": "Indonesian", "it": "Italian",
        "ja": "Japanese", "kn": "Kannada", "ko": "Korean", "ms": "Malay",
        "zh": "Mandarin Chinese", "zh-cn": "Mandarin Chinese",
        "zh-hans": "Mandarin Chinese", "mr": "Marathi", "pl": "Polish",
        "pt": "Portuguese", "es": "Spanish", "tl": "Tagalog", "fil": "Tagalog",
        "ta": "Tamil", "te": "Telugu", "th": "Thai", "tr": "Turkish",
        "vi": "Vietnamese",
    ]

    /// Maps a stored token (ISO code, Auto, or full name) onto the API name.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return auto }
        let key = trimmed.lowercased()
        if let alias = aliases[key] { return alias }
        if let name = names.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return name
        }
        return trimmed
    }

    public static func wireValues(from stored: String) -> [String] {
        stored.split(separator: ",").map { normalize(String($0)) }.filter { !$0.isEmpty && names.contains($0) }
    }

    /// Picker selection: Auto, or the first language in a stored list.
    public static func selection(from stored: String) -> String {
        wireValues(from: stored).first ?? auto
    }
}

/// Session settings for one dictation press.
public struct MetaSessionConfig: Sendable, Equatable, Hashable {
    public static let defaultModel = "muse-voice-transcribe-1.0"
    public static let maxKeywords = 100
    public static let maxKeywordLength = 50

    public var apiKey: String
    public var model: String
    public var mode: MetaTranscriptionMode
    public var audioEncoding: MetaAudioEncoding
    public var partialMode: MetaPartialMode
    public var languageBias: [String]
    public var keywords: [String]
    public var sessionId: String?

    public init(
        apiKey: String,
        audioEncoding: MetaAudioEncoding,
        model: String = defaultModel,
        mode: MetaTranscriptionMode = .pushToTalk,
        partialMode: MetaPartialMode = .cumulative,
        languageBias: [String] = [],
        keywords: [String] = [],
        sessionId: String? = nil
    ) {
        self.apiKey = apiKey
        self.audioEncoding = audioEncoding
        self.model = model
        self.mode = mode
        self.partialMode = partialMode
        self.languageBias = languageBias
        self.keywords = keywords
        self.sessionId = sessionId
    }

    /// Builds a session from provider-agnostic values. Throws when the
    /// required audio encoding is unset or unrecognized, or the key is blank.
    public init(from config: ProviderConfiguration) throws {
        guard let key = config.apiKey else {
            throw TranscriptionError.auth("Missing Meta API key. Add an API key in Settings → Providers.")
        }
        guard let token = config.string(ProviderConfiguration.Key.audioEncoding),
            let encoding = MetaAudioEncoding(rawValue: token)
        else {
            throw TranscriptionError(
                kind: .decoding, message: "Missing or unrecognized audioEncoding; expected PCM_16KHZ or PCM_24KHZ.")
        }
        // A stored mode the server does not know would silently transcribe
        // in the wrong mode (and change the completion policy), so an
        // unrecognized non-empty value is rejected loudly. An absent value
        // keeps the default.
        let mode: MetaTranscriptionMode
        if let storedMode = config.string(ProviderConfiguration.Key.mode), !storedMode.isEmpty {
            guard let parsed = MetaTranscriptionMode(rawValue: storedMode) else {
                throw TranscriptionError(
                    kind: .decoding,
                    message: "Unrecognized recognition mode \"\(storedMode)\"; "
                        + "expected PUSH_TO_TALK, ENDPOINTING, or DIARIZATION.")
            }
            mode = parsed
        } else {
            mode = .pushToTalk
        }
        let partial =
            config.string(ProviderConfiguration.Key.partialMode).flatMap(MetaPartialMode.init(rawValue:))
            ?? .cumulative
        let bias = MetaLanguageBias.wireValues(
            from: config.string(ProviderConfiguration.Key.languageBias) ?? MetaLanguageBias.auto)
        self.init(
            apiKey: key,
            audioEncoding: encoding,
            model: config.nonBlankString(ProviderConfiguration.Key.model, default: Self.defaultModel),
            mode: mode,
            partialMode: partial,
            languageBias: bias,
            keywords: Self.sanitizedKeywords(config.stringList(ProviderConfiguration.Key.keywords)),
            sessionId: config.string(ProviderConfiguration.Key.sessionId))
    }

    public var completionPolicy: TranscriptCompletionPolicy {
        mode == .pushToTalk ? .finalEvent : .turnComplete
    }

    /// Caps keywords to the streaming API limits (100 terms, 50 characters).
    public static func sanitizedKeywords(_ raw: [String]) -> [String] {
        Array(
            raw.map { String($0.prefix(maxKeywordLength)) }.filter { !$0.isEmpty }.prefix(maxKeywords))
    }
}

/// Pure encoding/decoding for the voice transcribe wire protocol.
///
/// No sockets here: frames go in and out as `Data` so every shape is
/// unit-testable without a network.
public enum MetaWireProtocol {
    /// Builds the JSON handshake. `audioEncoding` is always emitted.
    public static func encodeHandshake(config: MetaSessionConfig) -> Data {
        var payload: [String: Any] = [
            "model": config.model,
            "mode": config.mode.rawValue,
            "partialMode": config.partialMode.rawValue,
            "audioEncoding": config.audioEncoding.rawValue,
            // Default is true server-side: one ignored audioProgress event
            // per processed chunk (~12/s). Opt out; Iris ignores them.
            "emitAudioProgress": false,
            "authorization": ["accessToken": "Bearer \(config.apiKey)"],
        ]
        if !config.languageBias.isEmpty {
            payload["languageBias"] = config.languageBias
        }
        if !config.keywords.isEmpty {
            payload["keywords"] = config.keywords
        }
        if let sessionId = config.sessionId, !sessionId.isEmpty {
            payload["sessionId"] = sessionId
        }
        // Keys above are JSON-safe; force-try is unreachable in practice.
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Builds the end-of-stream marker sent on key release.
    public static func encodeEndStream() -> Data {
        Data(#"{"type":"endStream"}"#.utf8)
    }

    /// True for the bare `{"sessionId": ...}` ACK, which carries no `type`.
    /// The client must wait for it before sending audio.
    public static func isHandshakeAck(_ json: Data) -> Bool {
        guard let object = decodeObject(json),
            object["type"] == nil,
            object["sessionId"] is String
        else { return false }
        return true
    }

    /// Maps one server JSON frame onto a domain event. Returns nil for the
    /// handshake ACK and for unknown or unusable shapes (which are ignored).
    public static func decodeServerEvent(_ json: Data, mode: MetaTranscriptionMode = .pushToTalk) -> TranscriptionEvent?
    {
        guard let object = decodeObject(json), let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "transcript":
            guard let text = object["transcript"] as? String else { return nil }
            let isFinal = Self.boolValue(object["final"])
            // Endpointing-style sessions complete on turn boundaries, so
            // transcripts there stay partial even if flagged final.
            if isFinal, mode == .pushToTalk {
                // An empty final is the server's "no speech" completion:
                // honor it so a quiet take finishes cleanly instead of
                // timing out or surfacing a server-closed error.
                return .final(text)
            }
            guard !text.isEmpty else { return nil }
            return .partial(text)
        case "speechComplete":
            let turnId = Self.turnIdentifier(object)
            let text = object["transcript"] as? String ?? ""
            if turnId.isEmpty, text.isEmpty { return nil }
            return .speechComplete(turnId: turnId, transcript: text)
        case "speechStarted", "speechStart":
            return .speechStarted
        case "error":
            return .error(classifyError(object))
        default:
            return nil
        }
    }

    // MARK: - Private

    /// Servers are loose with JSON scalars: flags arrive as true, 1, or "true".
    static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            default: return false
            }
        }
        if let number = value as? NSNumber { return number.intValue != 0 }
        return false
    }

    /// Servers are loose with JSON scalars: codes arrive as 401, 401.0, or "401".
    static func intCode(_ value: Any?) -> Int? {
        if value == nil || value is Bool { return nil }
        if let code = value as? Int { return code }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let code = Int(trimmed) { return code }
            if let double = Double(trimmed), let code = Int(exactly: double) { return code }
            return nil
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            if double == double.rounded(), let code = Int(exactly: double) { return code }
            return nil
        }
        return nil
    }

    /// Published SpeechComplete uses int32 `turnId`; some fixtures use strings.
    static func turnIdentifier(_ object: [String: Any]) -> String {
        if let text = object["turnId"] as? String { return text }
        if let number = object["turnId"] as? NSNumber { return number.stringValue }
        return ""
    }

    private static func decodeObject(_ json: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any]
    }

    private static func classifyError(_ object: [String: Any]) -> TranscriptionError {
        // Meta's documented ErrorEvent carries `errorCode`/`errorType`
        // strings; some deployments also send numeric `code`/`status`.
        // Read every shape before falling back to message heuristics.
        let errorCode = (object["errorCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorType = (object["errorType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty errorCode must not mask a usable errorType.
        let stringCode = ((errorCode?.isEmpty == false ? errorCode : errorType) ?? "").lowercased()
        let code = intCode(object["code"]) ?? intCode(object["status"])
        let message = (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Transcription failed."
        if code == 401 || code == 403
            || stringCode.contains("auth") || stringCode.contains("invalid_api_key")
            || stringCode.contains("unauthorized")
        {
            return TranscriptionError(kind: .authentication, message: message)
        }
        if code == 429 || stringCode.contains("rate_limit") || stringCode.contains("quota") {
            return TranscriptionError(kind: .rateLimited, message: message)
        }
        // A validation error names what was invalid; never read it as a key
        // or rate problem from words such as "invalid" or "sample rate".
        if stringCode.contains("invalid_request") {
            return TranscriptionError(kind: .unknown, message: message)
        }
        if let kind = TranscriptionError.classifiedServerPhrase(in: stringCode) {
            return TranscriptionError(kind: kind, message: message)
        }
        if stringCode.contains("stream") && stringCode.contains("limit") {
            return TranscriptionError(kind: .streamLimit, message: message)
        }
        let lower = message.lowercased()
        if let kind = TranscriptionError.classifiedServerPhrase(in: lower) {
            return TranscriptionError(kind: kind, message: message)
        }
        return TranscriptionError(kind: .unknown, message: message)
    }
}
