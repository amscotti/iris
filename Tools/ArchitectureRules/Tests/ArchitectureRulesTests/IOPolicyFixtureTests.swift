import Foundation
import Testing

extension ArchitectureRules {

    @Test func providerIOPolicyAllowsTransportAndRewriteRequestValues() {
        let source = """
            import Foundation
            import IrisCore
            func stream(_ transport: any ByteStream, frame: PCMFrame) async throws {
                try await transport.connect()
                try await transport.write(frame.asData())
            }
            let endpoint = URLComponents()
            let request = RewriteHTTPRequest(url: url, headers: [:], body: Data())
            let descriptor = MetaProvider().descriptor
            let documentation = "URLSession.shared; FileManager.default"
            """
        #expect(SourcePolicy.identifiers(in: source).isDisjoint(with: SourcePolicy.providerLiveIOIdentifiers))
        #expect(SourcePolicy.selectedFileIOReferences(in: source).isEmpty)
    }

    @Test func providerIOPolicyFindsQualifiedImportsAliasesAndDormantBranches() {
        let source = #"""
            import class Foundation.URLSession
            typealias Connection = Foundation.NSURLConnection
            let make = Foundation.URLSessionConfiguration.ephemeral
            #if FUTURE_PROVIDER
            let stream = OutputStream(toMemory: ())
            let socket = NWConnection(host: host, port: port, using: .tcp)
            #endif
            let documentation = "InputStream and CFReadStreamOpen"
            // FileManager.default
            let interpolation = "session \(URLSession.shared)"
            """#
        let names = Set(
            SourcePolicy.identifierReferences(in: source, matching: SourcePolicy.providerLiveIOIdentifiers).map(\.api))
        #expect(names == ["URLSession", "NSURLConnection", "URLSessionConfiguration", "OutputStream", "NWConnection"])
        #expect(SourcePolicy.selectedFileIOReferences(in: "let bytes = try Data(contentsOf: remoteURL)").count == 1)
    }

    @Test func hotkeyEdgePayloadClassificationStaysInThePureGuard() {
        #expect(SourcePolicy.pureTransitionPaths.contains("Sources/IrisMacOS/Runtime/HotkeyEdgeState.swift"))
        let pure = """
            struct Edge {
                mutating func handle(_ event: NSEvent) -> HotkeyEvent? {
                    let flags = NSEvent.ModifierFlags(rawValue: event.modifierFlags.rawValue)
                    return flags.contains(.option) && event.keyCode == 61 ? .pressed : nil
                }
            }
            """
        #expect(SourcePolicy.identifiers(in: pure).isDisjoint(with: SourcePolicy.pureTransitionEffects))
        for effect in [
            "let held = CGEventSource.keyState(.combinedSessionState, key: 61)",
            "NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }",
            "let trusted = AXIsProcessTrusted()", "Task { record() }", "let now = Date()",
        ] {
            #expect(!SourcePolicy.identifiers(in: effect).isDisjoint(with: SourcePolicy.pureTransitionEffects))
        }
    }

    @Test func audioStorageSelectionIncludesCoreProvidersAndCapturerButNotApplicationPersistence() {
        for path in [
            "Sources/IrisCore/Domain/PCMFrame.swift", "Sources/IrisCore/Config/SettingsRepository.swift",
            "Sources/IrisProviders/Future/Codec.swift", "Sources/IrisMacOS/Runtime/AVAudioEngineCapturer.swift",
        ] {
            #expect(SourcePolicy.isAudioStorageScope(path))
        }
        for path in [
            "Sources/IrisMacOS/Adapters/Persistence.swift", "Sources/IrisMacOS/Adapters/PermissionsManager.swift",
            "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift", "Sources/IrisCoreTests/Fixture.swift",
        ] {
            #expect(!SourcePolicy.isAudioStorageScope(path))
        }
    }

    @Test func audioStoragePolicyFindsSelectedWritersProcessesAndNotDocumentation() {
        let source = #"""
            let file = AVAudioFile(forWriting: url, settings: settings)
            let handle = Foundation.FileHandle(forWritingTo: url)
            let output = OutputStream(toFileAtPath: path, append: true)
            FileManager.default.createFile(atPath: path, contents: bytes)
            let process = Foundation.Process()
            fwrite(samples, 2, count, file)
            let documentation = "AVAudioRecorder FileManager Process pwrite"
            // UserDefaults.standard
            """#
        let names = Set(
            SourcePolicy.identifierReferences(in: source, matching: SourcePolicy.audioStorageIdentifiers).map(\.api))
        #expect(names == ["AVAudioFile", "FileHandle", "OutputStream", "FileManager", "Process", "fwrite"])
    }

    @Test func fileIOPolicyFindsTypedDataLocalConstructorsAndCapturedWriteReferences() {
        let source = """
            typealias Bytes = Foundation.Data
            typealias Payload = Bytes
            func save(_ raw: Payload, optional: Data?) throws {
                try raw.write(to: url)
                let local = Foundation.Data([1, 2])
                let write = local.write(to:options:)
                try optional?.write(to: url)
                let inferred: Data = .init([3])
                try inferred.write(to: url)
                try Data([4]).write(to: url)
            }
            """
        let references = SourcePolicy.selectedFileIOReferences(in: source)
        #expect(references == Array(repeating: .init(owner: "save", api: "Data.write"), count: 5))
    }

    @Test func fileIOPolicyFindsAudioAndSerializationValueProducers() {
        let source = """
            func save(frame: PCMFrame, message: TransportMessage, request: RewriteHTTPRequest, text: String) throws {
                try frame.asData().write(to: url)
                try message.data.write(to: url)
                try request.body.write(to: url)
                try JSONSerialization.data(withJSONObject: object).write(to: url)
                let encoder = JSONEncoder()
                try encoder.encode(value).write(to: url)
                try text.data(using: .utf8)?.write(to: url)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            """
        let references = SourcePolicy.selectedFileIOReferences(in: source)
        #expect(references.filter { $0.api == "Data.write" }.count == 6)
        #expect(references.filter { $0.api == "String.write" }.count == 1)
    }

    @Test func fileIOPolicyFollowsPropertiesAndSelfWithinTheSameFile() {
        let source = """
            struct AudioBuffer {
                let bytes = Data([1])
                func dump() throws { try self.bytes.write(to: url) }
            }
            extension AudioBuffer {
                func dumpFromExtension() throws { try bytes.write(to: url) }
            }
            """
        #expect(
            SourcePolicy.selectedFileIOReferences(in: source) == [
                .init(owner: "AudioBuffer.dump", api: "Data.write"),
                .init(owner: "AudioBuffer.dumpFromExtension", api: "Data.write"),
            ])
    }

    @Test func fileIOPolicyFindsDirectLoadsIncludingContextualInitializers() {
        let source = """
            func load() throws {
                let bytes = try Foundation.Data(contentsOf: url)
                let typed: Data = try .init(contentsOf: url)
                let text = try String(contentsOfFile: path, encoding: .utf8)
            }
            """
        #expect(
            SourcePolicy.selectedFileIOReferences(in: source).map(\.api) == [
                "Data.init(contentsOf:)", "Data.init(contentsOf:)", "String.init(contentsOfFile:)",
            ])
    }

    @Test func fileIOPolicyAllowsPortsUnrelatedWritesAndLexicalShadowing() {
        let source = """
            func send(_ transport: any ByteStream, bytes: Data, writer: OtherWriter) async throws {
                try await transport.write(bytes)
                writer.write(to: destination)
                try persistence.save(bytes, forKey: key)
            }
            func shadow(_ bytes: Data) throws {
                if condition {
                    let bytes = OtherWriter()
                    bytes.write(to: destination)
                }
                try bytes.write(to: url)
            }
            func unrelated(_ bytes: OtherWriter) { bytes.write(to: destination) }
            """
        #expect(SourcePolicy.selectedFileIOReferences(in: source) == [.init(owner: "shadow", api: "Data.write")])
    }

    @Test func fileIOPolicyInspectsConditionalInterpolationAndMacroArgumentsNotLiteralText() {
        let source = #"""
            let documentation = "Data([1]).write(to: url); PermissionsManager()"
            // try Data([1]).write(to: url)
            #if NEVER_ENABLED
            let actual = "result \(try Data([1]).write(to: url))"
            #else
            #Review(try Data([2]).write(to: url))
            #endif
            """#
        #expect(SourcePolicy.selectedFileIOReferences(in: source).map(\.api) == ["Data.write", "Data.write"])
    }

    @Test func fileIOPolicyDocumentsUnresolvedFactoryAndAliasLimitsWithoutRecursingForever() {
        let source = """
            typealias CycleA = CycleB
            typealias CycleB = CycleA
            func unresolved(_ value: CycleA) {
                value.write(to: url)
                externalFactory().write(to: url)
            }
            """
        // These are not proved safe; compiler types/external function bodies
        // and arbitrary factories are explicitly outside this syntax check.
        #expect(SourcePolicy.selectedFileIOReferences(in: source).isEmpty)
    }

    @Test func previewPolicyAllowsDescriptorsMockPortsAndSnapshotPermissionInitializers() {
        let source = """
            typealias SnapshotPermissions = IrisMacOS.PermissionsManager
            let registry = AppProviderAssembly.defaultRegistry()
            let descriptor = MetaProvider().descriptor
            let other = GrokProvider().descriptor
            let client = MockTranscriptionClient()
            let ports = PreviewRuntime.ports()
            let clipboard = PreviewClipboard()
            let permissions = PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true)
            let qualified = IrisMacOS.PermissionsManager.init(microphoneStatus: .denied, accessibilityGranted: false)
            let alias = SnapshotPermissions(microphoneStatus: .granted, accessibilityGranted: true)
            let contextual: PermissionsManager = .init(microphoneStatus: .granted, accessibilityGranted: true)
            let parenthesized: PermissionsManager = (.init(microphoneStatus: .denied, accessibilityGranted: false))
            func snapshot() -> PermissionsManager { .init(microphoneStatus: .granted, accessibilityGranted: true) }
            let documentation = "PermissionsManager(); LiveClipboard(); URLSession.shared"
            """
        #expect(SourcePolicy.previewIOReferences(in: source).isEmpty)
    }

    @Test func previewPolicyRejectsLiveDefaultPermissionConstructionAndFactoryReferences() {
        let source = #"""
            typealias Permissions = IrisMacOS.PermissionsManager
            let direct = PermissionsManager()
            let qualified = IrisMacOS.PermissionsManager.init()
            let contextual: PermissionsManager = .init()
            let parenthesized: PermissionsManager = (.init())
            let alias = Permissions()
            let partial = PermissionsManager(microphoneStatus: .granted)
            let make = PermissionsManager.init
            let metatype = PermissionsManager.self
            let actual = "\(PermissionsManager())"
            """#
        let references = SourcePolicy.previewIOReferences(in: source)
        #expect(references.filter { $0.api == "PermissionsManager.liveInitializer" }.count == 7)
        #expect(references.filter { $0.api == "PermissionsManager.factoryReference" }.count == 2)
    }

    @Test func previewPermissionPolicyUsesArgumentSyntaxNotLabelsInsideCommentsOrStrings() {
        let source = """
            let comment = PermissionsManager(/* microphoneStatus: .granted, accessibilityGranted: true */)
            let string = PermissionsManager(example: "microphoneStatus: .granted, accessibilityGranted: true")
            func contextual() -> PermissionsManager { return .init() }
            """
        #expect(
            SourcePolicy.previewIOReferences(in: source).map(\.api)
                == Array(
                    repeating: "PermissionsManager.liveInitializer", count: 3))
    }

    @Test func previewPolicyRejectsSelectedLiveAdaptersEvenInTheCaptureTool() {
        let source = """
            extension SettingsPreview {
                func capture() {
                    AVAudioEngineCapturer()
                    let monitor = GlobalHotkeyMonitor.init
                    let storage = UserDefaultsPersistence()
                    KeychainSecretStore()
                    URLSessionWebSocketTransport(url: url)
                    LiveClipboard()
                    RewriteChatClient(configuration: config, registry: registry)
                }
            }
            """
        let path = "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift"
        let references = SourcePolicy.previewIOReferences(in: source)
        #expect(
            Set(references.map(\.api)) == [
                "AVAudioEngineCapturer", "GlobalHotkeyMonitor", "UserDefaultsPersistence", "KeychainSecretStore",
                "URLSessionWebSocketTransport", "LiveClipboard", "RewriteChatClient",
            ])
        #expect(references.allSatisfy { SourcePolicy.previewIOExceptions[path + "#" + $0.key] == nil })
    }

    @Test func previewDeveloperOutputExceptionsRemainFileOwnerAPIAndCountSpecific() {
        let source = """
            extension SettingsPreview {
                static func capture() throws {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let fact = ApplicationImage.isCurrent()
                    try JSONSerialization.data(withJSONObject: report).write(to: url)
                }
                static func snapshot(_ bitmap: NSBitmapImageRep) throws {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
            """
        let references = SourcePolicy.previewIOReferences(in: source)
        let path = "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift"
        var actual: [String: Int] = [:]
        for reference in references { actual[path + "#" + reference.key, default: 0] += 1 }
        #expect(actual == SourcePolicy.previewIOExceptions.mapValues(\.count))
        #expect(
            references.allSatisfy {
                SourcePolicy.previewIOExceptions["Sources/IrisMacOS/App/Preview/SettingsPreview.swift#" + $0.key] == nil
            })
        #expect(SourcePolicy.previewIOExceptions[path + "#SettingsPreview.makeEnvironment#FileManager"] == nil)
        let duplicated = source.replacingOccurrences(
            of: "let fact = ApplicationImage.isCurrent()",
            with: "let facts = (ApplicationImage.isCurrent(), ApplicationImage.isCurrent())")
        #expect(SourcePolicy.previewIOReferences(in: duplicated).filter { $0.api == "ApplicationImage" }.count == 2)
    }

}
