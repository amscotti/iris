import Foundation
import Harmonize
import Testing

extension ArchitectureRules {

    @Test func coreImportsOnlyPortableModules() throws {
        let sources = try Repository.sources("Sources/IrisCore")
        sources.assertTrue(message: "Core imports only Foundation/Swift; concrete providers are a separate module") {
            SourcePolicy.importedModules(in: $0.source).isSubset(of: SourcePolicy.coreImportAllowlist)
        }
    }

    @Test func providersDependOnlyOnCoreAndPortableModules() throws {
        let sources = try Repository.sources("Sources/IrisProviders")
        sources.assertTrue(message: "Provider implementation must not depend on the macOS application") {
            SourcePolicy.importedModules(in: $0.source).isSubset(of: SourcePolicy.providerImportAllowlist)
        }
    }

    @Test func coreDoesNotReferenceSelectedLiveIOAPIs() throws {
        try Repository.sources("Sources/IrisCore").assertTrue(
            message: "Core cannot reference the listed network, persistence, process, or platform I/O APIs"
        ) { SourcePolicy.identifiers(in: $0.source).isDisjoint(with: SourcePolicy.coreLiveIOIdentifiers) }
    }

    @Test func runtimeDoesNotReachBackIntoComposition() throws {
        // Composition lives in App/; every other IrisMacOS subtree must stay
        // free of back-references into it (not just Runtime/).
        for scope in ["Sources/IrisMacOS/Runtime", "Sources/IrisMacOS/Adapters", "Sources/IrisMacOS/UI"] {
            try Repository.sources(scope).assertTrue(
                message: "\(scope) cannot reference AppComposition or AppProviderAssembly"
            ) { SourcePolicy.identifiers(in: $0.source).isDisjoint(with: ["AppComposition", "AppProviderAssembly"]) }
        }
    }

    @Test func viewsDoNotReferenceSelectedLiveIOAdapters() throws {
        // Carve-out: NSApplication/NSWorkspace are permitted in UI for window
        // activation and accessibility-display queries (SettingsWindowController
        // owns an AppKit window by design). They must not become a route to
        // live IO; adapter types — including adapter-owned value types such as
        // PermissionDiagnostics and MicrophoneStatus — stay forbidden so the
        // facade cannot leak them back into view signatures.
        let forbidden: Set<String> = [
            "LiveClipboard", "AVAudioEngineCapturer", "GlobalHotkeyMonitor", "KeychainSecretStore",
            "UserDefaultsPersistence", "URLSessionWebSocketTransport", "RewriteChatClient", "Process",
            "AccessControlTextInserter", "LiveFocus", "LiveKeyPosting", "NSPasteboard", "UserDefaults",
            "URLSession", "FileManager", "FileHandle", "CGEvent", "SecItemCopyMatching", "SecItemAdd",
            "SecItemUpdate", "SecItemDelete", "PermissionsManager", "PermissionDiagnostics",
            "MicrophoneStatus",
        ]
        try Repository.sources("Sources/IrisMacOS/UI").assertTrue(
            message: "UI cannot reference the listed live I/O adapters and APIs; composition supplies them"
        ) {
            SourcePolicy.identifiers(in: $0.source).isDisjoint(with: forbidden)
                && SourcePolicy.selectedFileIOReferences(in: $0.source).isEmpty
        }
    }

    @Test func observableStateAndReviewedControllersAreMainActorAnnotated() throws {
        let roles: Set<String> = [
            "AppEnvironment", "SettingsController", "ProviderAccessController", "DictationRuntime", "PillController",
            "PillViewModel",
            "ProviderCredentials", "ProviderConnections", "PermissionsManager", "SettingsWindowController",
        ]
        // The observable inventory is a ceiling, not a floor: a new
        // @Observable class must be reviewed and added here explicitly.
        let observableRoles: Set<String> = [
            "AppEnvironment", "SettingsController", "ProviderAccessController", "DictationRuntime", "PillController",
            "PillViewModel", "ProviderCredentials", "ProviderConnections", "PermissionsManager",
        ]
        let sources = try Repository.sources("Sources/IrisMacOS")
        let classes = sources.flatMap { SourcePolicy.classes(in: $0.source) }
        let reviewed = classes.filter { roles.contains($0.name) }
        try #require(
            Set(reviewed.map(\.name)) == roles && reviewed.count == roles.count,
            "Each reviewed presentation/controller role must have exactly one class declaration")
        try #require(classes.contains { $0.isObservable }, "Observable state selection matched no classes")
        let observables = classes.filter { $0.isObservable }
        try #require(
            Set(observables.map(\.name)) == observableRoles && observables.count == observableRoles.count,
            "Every @Observable class must be a reviewed role with exactly one declaration")
        for source in sources {
            let missing = SourcePolicy.classes(in: source.source).filter {
                ($0.isObservable || roles.contains($0.name)) && !$0.isMainActor
            }
            let path = try Repository.relativePath(source)
            let names = missing.map(\.qualifiedName).joined(separator: ", ")
            #expect(
                missing.isEmpty,
                "Missing unconditional @MainActor in \(path): \(names)")
        }
    }

    @Test func dictationOrchestratorRemainsAnActor() throws {
        let actors = try Repository.sources("Sources/IrisCore/Transcription").actors()
        #expect(
            actors.filter { $0.name == "DictationOrchestrator" }.count == 1,
            "Exactly one DictationOrchestrator actor declaration must remain in the transcription scope")
    }

    @Test func declaredTargetGraphPreservesTheModuleBoundaries() throws {
        let expected: [String: Set<String>] = [
            "IrisCore": [], "IrisProviders": ["IrisCore"], "IrisMacOS": ["IrisCore", "IrisProviders"],
            "MockASRServer": [], "IrisCoreTests": ["IrisCore", "IrisProviders"],
            "IrisMacOSTests": ["IrisCore", "IrisProviders", "IrisMacOS"],
        ]
        #expect(
            try Repository.declaredDependencies() == expected, "Module edges are an explicit architectural decision")
    }

}
