import Foundation
import IrisCore

/// xAI-specific behavior stays here and in Grok's wire/client files.
public struct GrokProvider: DictationProvider {
    public let id = ProviderID.grok
    public init() {}

    public var information: ProviderInformation {
        ProviderInformation(
            serviceName: "Speech to text by xAI", accountName: "xAI", apiKeyURL: URL(string: "https://console.x.ai/"))
    }

    public static let rewriteDescriptor = RewriteDescriptor(
        provider: .grok, defaultModel: "grok-4.6", defaultEffort: .low,
        effortCases: [.low, .medium, .high, .xhigh],
        effortCaption: "Grok 4.6 always reasons. Low is fastest; higher reasoning can add time.",
        effortAliases: [.minimal: .low, .max: .xhigh], legacyModelPrefixes: ["grok-"])

    public var rewriter: (any RewriteAdapter)? {
        ChatCompletionsAdapter(
            descriptor: Self.rewriteDescriptor, endpoint: "https://api.x.ai/v1/chat/completions",
            instructionRole: "system")
    }

    public var descriptor: ConfigDescriptor { Self.settingsDescriptor }

    private static let settingsDescriptor = ConfigDescriptor(
        fields: [
            ConfigField(
                key: ProviderConfiguration.Key.model, label: "Speech model",
                type: .enumAllowingCustom(cases: [
                    GrokSessionConfig.defaultModel, GrokSessionConfig.originalModel,
                ]),
                defaultValue: GrokSessionConfig.defaultModel, advanced: true),
            ConfigField(
                key: ProviderConfiguration.Key.languageBias, label: "Language",
                type: .enum(cases: [GrokLanguage.auto] + GrokLanguage.codes),
                defaultValue: GrokLanguage.auto,
                optionLabels: Dictionary(uniqueKeysWithValues: GrokLanguage.choices.map { ($0.code, $0.label) })
                    .merging([GrokLanguage.auto: "Automatic"]) { _, label in label },
                hint: "Choose a language to format numbers and currencies. Automatic leaves them as spoken."),
            ConfigField(
                key: ProviderConfiguration.Key.keywords, label: "Custom words",
                type: .string, defaultValue: "",
                hint: "Names and terms that are often misheard, separated by commas."),
            ConfigField(
                key: ProviderConfiguration.Key.apiKey, label: "API key",
                type: .secret, defaultValue: ""),
        ] + rewriteDescriptor.configFields)

    public func makeClient(
        config: ProviderConfiguration, transport: any ByteStream
    ) -> any TranscriptionClient {
        GrokVoiceTranscribeClient(transport: transport)
    }

    public func connection(for config: ProviderConfiguration) -> SpeechConnection? {
        guard let key = config.apiKey else {
            return SpeechConnection(url: GrokVoiceTranscribeClient.endpointURL(from: config))
        }
        // The Bearer key rides the WebSocket upgrade headers; a key with
        // header delimiters would be dropped by the network stack and the
        // request would silently go out unauthenticated, so build no
        // connection for it. The client surfaces the explicit auth error.
        guard !TranscriptionError.apiKeyContainsInvalidCharacters(key) else { return nil }
        return SpeechConnection(
            url: GrokVoiceTranscribeClient.endpointURL(from: config),
            headers: ["Authorization": "Bearer \(key)"])
    }

    public func displayValue(_ value: String, for key: String) -> String {
        key == ProviderConfiguration.Key.languageBias ? GrokLanguage.selection(from: value) : value
    }
}

extension ProviderID {
    public static let grok = ProviderID("Grok")
}
