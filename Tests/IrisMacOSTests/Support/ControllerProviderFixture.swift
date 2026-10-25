import IrisCore

/// Two required secrets exercise descriptor-driven policy beyond the built-in apiKey.
struct ControllerProviderFixture: DictationProvider {
    let id = ProviderID("Credential fixture")
    var descriptor: ConfigDescriptor {
        ConfigDescriptor(fields: [
            ConfigField(key: "apiKey", label: "API key", type: .secret, defaultValue: ""),
            ConfigField(key: "token", label: "Token", type: .secret, defaultValue: ""),
            ConfigField(key: "languageBias", label: "Language", type: .string, defaultValue: "xx"),
        ])
    }
    func normalizeConfiguration(_ values: [String: String]) -> [String: String] {
        values.merging(["normalizedBy": id.name]) { _, normalized in normalized }
    }
    func makeClient(config: ProviderConfiguration, transport: any ByteStream) -> any TranscriptionClient {
        UnavailableTranscriptionClient()
    }
}
