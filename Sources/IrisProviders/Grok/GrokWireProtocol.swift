import Foundation
import IrisCore

/// Languages the streaming STT API formats when `language` is set.
/// Empty means Auto: omit the query parameter so the model detects speech
/// without Inverse Text Normalization.
public enum GrokLanguage {
    public static let auto = ""

    public struct Choice: Sendable, Equatable, Hashable {
        public var code: String
        public var label: String
    }

    public static let choices: [Choice] = [
        Choice(code: "ar", label: "Arabic"),
        Choice(code: "cs", label: "Czech"),
        Choice(code: "da", label: "Danish"),
        Choice(code: "nl", label: "Dutch"),
        Choice(code: "en", label: "English"),
        Choice(code: "fil", label: "Filipino"),
        Choice(code: "fr", label: "French"),
        Choice(code: "de", label: "German"),
        Choice(code: "hi", label: "Hindi"),
        Choice(code: "id", label: "Indonesian"),
        Choice(code: "it", label: "Italian"),
        Choice(code: "ja", label: "Japanese"),
        Choice(code: "ko", label: "Korean"),
        Choice(code: "mk", label: "Macedonian"),
        Choice(code: "ms", label: "Malay"),
        Choice(code: "fa", label: "Persian"),
        Choice(code: "pl", label: "Polish"),
        Choice(code: "pt", label: "Portuguese"),
        Choice(code: "ro", label: "Romanian"),
        Choice(code: "ru", label: "Russian"),
        Choice(code: "es", label: "Spanish"),
        Choice(code: "sv", label: "Swedish"),
        Choice(code: "th", label: "Thai"),
        Choice(code: "tr", label: "Turkish"),
        Choice(code: "vi", label: "Vietnamese"),
    ]

    public static var codes: [String] { choices.map(\.code) }

    /// Maps a stored token (ISO code, Auto, or English label) onto the API code.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return auto }
        let key = trimmed.lowercased()
        if key == "auto" { return auto }
        if choices.contains(where: { $0.code == key }) { return key }
        if let match = choices.first(where: { $0.label.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match.code
        }
        return key
    }

    /// Picker selection: Auto, or a known ISO code.
    public static func selection(from stored: String) -> String {
        let code = normalize(stored)
        return choices.contains(where: { $0.code == code }) ? code : auto
    }

    public static func label(for code: String) -> String {
        choices.first(where: { $0.code == code })?.label ?? code
    }
}

/// Session settings for one Grok dictation press.
public struct GrokSessionConfig: Sendable, Equatable, Hashable {
    public static let sampleRate = 16_000
    public static let encoding = "pcm"
    public static let defaultModel = "grok-voice-transcribe-2.0"
    public static let originalModel = "grok-voice-transcribe-1.0"
    public static let maxKeyterms = 100
    public static let maxKeytermLength = 50

    public var apiKey: String
    public var model: String
    public var language: String
    public var keyterms: [String]

    public init(
        apiKey: String, model: String = defaultModel,
        language: String = GrokLanguage.auto, keyterms: [String] = []
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.keyterms = keyterms
    }

    /// Builds a session from provider-agnostic values. Throws when the key
    /// is blank or contains characters that must not enter an HTTP header.
    public init(from config: ProviderConfiguration) throws {
        guard let key = config.apiKey else {
            throw TranscriptionError.auth("Missing Grok API key. Add an xAI key in Settings → Providers.")
        }
        guard !TranscriptionError.apiKeyContainsInvalidCharacters(key) else {
            throw TranscriptionError.auth(TranscriptionError.invalidAPIKeyCharactersMessage)
        }
        // selection (not normalize): unknown tokens become Auto here just
        // as they do on the wire, so wire-identical configs compare equal.
        let language = GrokLanguage.selection(
            from: config.string(ProviderConfiguration.Key.languageBias) ?? GrokLanguage.auto)
        self.init(
            apiKey: key,
            model: config.nonBlankString(ProviderConfiguration.Key.model, default: Self.defaultModel),
            language: language,
            keyterms: Self.sanitizedKeyterms(config.stringList(ProviderConfiguration.Key.keywords)))
    }

    public var completionPolicy: TranscriptCompletionPolicy { .finalEvent }

    /// Caps keyterms to the streaming API limits (100 terms, 50 characters).
    public static func sanitizedKeyterms(_ raw: [String]) -> [String] {
        Array(
            raw.map { String($0.prefix(maxKeytermLength)) }.filter { !$0.isEmpty }.prefix(maxKeyterms))
    }
}

/// Pure encoding/decoding for the Grok streaming STT wire protocol.
///
/// No sockets here: frames go in and out as `Data` so every shape is
/// unit-testable without a network.
public enum GrokWireProtocol {
    /// Builds the end-of-audio marker sent on key release. The server then
    /// emits `transcript.done` and closes. Iris is one socket per press, so
    /// this is `audio.done`, not `finalize` (which keeps the session open).
    public static func encodeAudioDone() -> Data {
        Data(#"{"type":"audio.done"}"#.utf8)
    }

    /// True for `transcript.created`, which the client must wait for before
    /// sending audio.
    public static func isReadyAck(_ json: Data) -> Bool {
        guard let object = decodeObject(json), eventType(object) == "transcript.created" else {
            return false
        }
        return true
    }

    /// Maps one server JSON frame onto a domain event. Returns nil for the
    /// ready ACK and for unknown or unusable shapes (which are ignored).
    ///
    /// Push-to-talk completes on `transcript.done` only. `speech_final` on a
    /// partial is a pause, not a release, so it stays a `.partial`.
    ///
    /// Test-only convenience: each call starts a fresh accumulator, so a
    /// `transcript.done` with empty text yields `.final("")`. Production
    /// accumulates across the session via the `accumulating:` overload.
    public static func decodeServerEvent(_ json: Data) -> TranscriptionEvent? {
        var transcript = GrokTranscriptAccumulator()
        return decodeServerEvent(json, accumulating: &transcript)
    }

    static func decodeServerEvent(
        _ json: Data, accumulating transcript: inout GrokTranscriptAccumulator
    ) -> TranscriptionEvent? {
        guard let object = decodeObject(json) else { return nil }
        guard let type = eventType(object) else { return nil }
        switch type {
        case "transcript.partial":
            let text = eventText(object)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .partial(
                transcript.append(
                    text: text,
                    start: object["start"] as? Double,
                    duration: object["duration"] as? Double,
                    isFinal: Self.boolValue(object["is_final"]),
                    speechFinal: Self.boolValue(object["speech_final"])))
        case "transcript.done":
            return .final(transcript.complete(with: eventText(object)))
        case "error":
            return .error(classifyError(object))
        default:
            return nil
        }
    }

    // MARK: - Private

    /// Servers are loose with JSON scalars: codes arrive as 401, 401.0, or
    /// "401"; flags arrive as true, 1, or "true".
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

    private static func decodeObject(_ json: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any]
    }

    /// The event name: `type`, with `event` as an alias. Shared by the
    /// ready-ACK gate and the decoder so an alias frame cannot satisfy one
    /// but stall the other.
    static func eventType(_ object: [String: Any]) -> String? {
        (object["type"] as? String) ?? (object["event"] as? String)
    }

    /// Streaming events use `text`; some payloads repeat it as `transcript`.
    static func eventText(_ object: [String: Any]) -> String {
        if let text = object["text"] as? String, !text.isEmpty { return text }
        if let text = object["transcript"] as? String { return text }
        return ""
    }

    private static func classifyError(_ object: [String: Any]) -> TranscriptionError {
        let nested = object["error"] as? [String: Any]
        let code =
            intCode(object["code"]) ?? intCode(object["status"])
            ?? intCode(nested?["code"]) ?? intCode(nested?["status"])
        let rawMessage =
            (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (nested?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let message = rawMessage ?? "Transcription failed."
        let codeString =
            ((object["code"] as? String) ?? (nested?["code"] as? String)
                ?? (nested?["type"] as? String) ?? "")
            .lowercased()
        switch code {
        case 401, 403:
            return TranscriptionError(kind: .authentication, message: message)
        case 429:
            return TranscriptionError(kind: .rateLimited, message: message)
        default:
            if let kind = TranscriptionError.classifiedServerPhrase(in: message.lowercased())
                ?? TranscriptionError.classifiedServerPhrase(in: codeString)
            {
                return TranscriptionError(kind: kind, message: message)
            }
            return TranscriptionError(kind: .unknown, message: message)
        }
    }
}
