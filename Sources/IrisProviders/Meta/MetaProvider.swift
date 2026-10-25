import Foundation
import IrisCore

/// Meta's complete application adapter: speech, rewrites, settings, and copy.
public struct MetaProvider: DictationProvider {
    public let id = ProviderID.meta
    public init() {}

    public var information: ProviderInformation {
        ProviderInformation(
            serviceName: "Muse Voice Transcribe", accountName: "Meta",
            apiKeyURL: URL(string: "https://dev.meta.ai/"))
    }

    public static let rewriteDescriptor = RewriteDescriptor(
        provider: .meta, defaultModel: "muse-spark-1.3",
        modelPresets: ["muse-spark-1.3", "muse-wonder-1.0"], defaultEffort: .minimal,
        effortCases: [.minimal, .low, .medium, .high, .xhigh, .max],
        effortCaption:
            "Minimal is fastest for simple cleanups. Higher reasoning takes longer. Max does not select Muse Wonder Full.",
        legacyModelPrefixes: ["muse-"])

    public var rewriter: (any RewriteAdapter)? {
        ChatCompletionsAdapter(
            descriptor: Self.rewriteDescriptor, endpoint: "https://api.meta.ai/v1/chat/completions",
            instructionRole: "developer")
    }

    public var descriptor: ConfigDescriptor { Self.settingsDescriptor }

    private static let settingsDescriptor = ConfigDescriptor(
        fields: [
            ConfigField(
                key: ProviderConfiguration.Key.model, label: "Speech model",
                type: .enumAllowingCustom(cases: [MetaSessionConfig.defaultModel]),
                defaultValue: MetaSessionConfig.defaultModel, advanced: true),
            ConfigField(
                key: ProviderConfiguration.Key.mode, label: "Recognition mode",
                type: .enum(cases: [
                    MetaTranscriptionMode.pushToTalk.rawValue,
                    MetaTranscriptionMode.endpointing.rawValue,
                    MetaTranscriptionMode.diarization.rawValue,
                ]), defaultValue: MetaTranscriptionMode.pushToTalk.rawValue,
                advanced: true,
                optionLabels: [
                    "PUSH_TO_TALK": "Push to talk", "ENDPOINTING": "Endpointing", "DIARIZATION": "Diarization",
                ]),
            ConfigField(
                key: ProviderConfiguration.Key.audioEncoding, label: "Audio encoding",
                type: .enum(cases: [
                    MetaAudioEncoding.pcm16k.rawValue,
                    MetaAudioEncoding.pcm24k.rawValue,
                ]), defaultValue: MetaAudioEncoding.pcm16k.rawValue,
                advanced: true, optionLabels: ["PCM_16KHZ": "Standard (16 kHz)", "PCM_24KHZ": "Higher (24 kHz)"],
                isVisible: false),
            ConfigField(
                key: ProviderConfiguration.Key.languageBias, label: "Language",
                type: .enum(cases: [MetaLanguageBias.auto] + MetaLanguageBias.names),
                defaultValue: MetaLanguageBias.auto,
                optionLabels: [MetaLanguageBias.auto: "Automatic"],
                hint: "A hint for the language you usually speak. Automatic lets the model detect it."),
            ConfigField(
                key: ProviderConfiguration.Key.keywords, label: "Custom words",
                type: .string, defaultValue: "",
                hint: "Names and terms that are often misheard, separated by commas."),
            ConfigField(
                key: ProviderConfiguration.Key.apiKey, label: "API key",
                type: .secret, defaultValue: ""),
        ] + rewriteDescriptor.configFields)

    public func connection(for config: ProviderConfiguration) -> SpeechConnection? {
        // One session id per press: both the URL query and the handshake
        // body read the same configured value, so the two can never
        // disagree on one connection.
        SpeechConnection(
            url: MetaVoiceTranscribeClient.endpointURL(
                sessionId: config.string(ProviderConfiguration.Key.sessionId)))
    }

    public func makeClient(
        config: ProviderConfiguration, transport: any ByteStream
    ) -> any TranscriptionClient {
        MetaVoiceTranscribeClient(transport: transport)
    }

    /// Completion policy for the configured mode, without exposing wire types.
    public func completionPolicy(for config: ProviderConfiguration) -> TranscriptCompletionPolicy {
        guard let raw = config.string(ProviderConfiguration.Key.mode),
            let mode = MetaTranscriptionMode(rawValue: raw)
        else { return .finalEvent }
        return mode == .pushToTalk ? .finalEvent : .turnComplete
    }

    public func normalizeConfiguration(_ values: [String: String]) -> [String: String] {
        var normalized = values
        // Match the app's canonical capture rate, including legacy 24 kHz settings.
        normalized[ProviderConfiguration.Key.audioEncoding] = MetaAudioEncoding.pcm16k.rawValue
        return normalized
    }

    public func displayValue(_ value: String, for key: String) -> String {
        key == ProviderConfiguration.Key.languageBias ? MetaLanguageBias.selection(from: value) : value
    }
}

extension ProviderID {
    public static let meta = ProviderID("Meta")
}
