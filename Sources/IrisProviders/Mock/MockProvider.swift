#if DEBUG
    import Foundation
    import IrisCore

    /// Offline fixture provider. It has neither a network connection nor a
    /// rewrite API, and opts out of end-user settings through its capabilities.
    public struct MockProvider: DictationProvider {
        public let id = ProviderID.mock
        public let isUserFacing = false
        public init() {}

        public var descriptor: ConfigDescriptor {
            ConfigDescriptor(fields: [
                ConfigField(key: "script", label: "Script", type: .string, defaultValue: "default"),
                ConfigField(key: "autoFinal", label: "Auto final", type: .bool, defaultValue: "true"),
            ])
        }

        public func makeClient(config: ProviderConfiguration, transport: any ByteStream) -> any TranscriptionClient {
            // The transport is intentionally unused: this is an offline fixture
            // with no network connection, so there is nothing to wire. The
            // script fields below are honored so provider-path tests exercise
            // the same replay behavior as directly constructed clients.
            _ = transport
            return MockTranscriptionClient(script: Self.script(for: config), autoFinal: Self.autoFinal(for: config))
        }

        /// `script` selects the replay: "default" (or absent) replays the
        /// standard hello script, "empty" replays the empty-final script, and
        /// any other value is spoken verbatim as both partial and final.
        static func script(for config: ProviderConfiguration) -> MockTranscriptionClient.Script {
            guard let raw = config.string("script")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty, raw.lowercased() != "default"
            else { return MockTranscriptionClient.Script() }
            if raw.lowercased() == "empty" { return MockTranscriptionClient.Script.emptyFinal }
            return MockTranscriptionClient.Script(partials: [raw], final: raw)
        }

        static func autoFinal(for config: ProviderConfiguration) -> Bool {
            config.bool("autoFinal", default: true)
        }
    }

    extension ProviderID {
        public static let mock = ProviderID("mock")
    }
#endif
