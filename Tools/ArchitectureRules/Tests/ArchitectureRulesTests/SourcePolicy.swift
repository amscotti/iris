import Foundation
import Harmonize
import SwiftParser
import SwiftSyntax
import Testing

/// Syntax checks ignore comments and literal text, but inspect executable
/// interpolation/macro arguments. Compilation supplies semantic import checking.
enum SourcePolicy {
    static let coreImportAllowlist: Set<String> = ["Foundation", "Swift"]
    static let providerImportAllowlist = coreImportAllowlist.union(["IrisCore"])

    /// Selected live APIs, not a ban on scheduling or clock reads in effect owners.
    /// The network spellings live here (not only in the provider union) so
    /// Core is held to the same live-IO bar as providers.
    static let coreLiveIOIdentifiers: Set<String> = [
        "URLSession", "NSURLSession", "NSURLConnection", "URLSessionConfiguration", "URLSessionTask",
        "URLSessionWebSocketTask", "Stream", "InputStream", "OutputStream",
        "CFStreamCreatePairWithSocketToHost", "CFReadStreamOpen", "CFWriteStreamOpen", "NWConnection",
        "NWListener", "UserDefaults",
        "FileManager", "FileHandle", "Process", "NSPasteboard", "CGEvent", "AVAudioEngine",
        "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete",
    ]
    /// Foundation is portable, but these spellings can execute I/O without a port.
    /// URL/URLComponents/URLRequest and RewriteHTTPRequest remain request values.
    static let providerLiveIOIdentifiers = coreLiveIOIdentifiers

    /// No blanket ban on Data, write, save, scheduling, or clocks: audio is
    /// encoded in memory and sent through ByteStream.write; settings use ports.
    static let audioStorageIdentifiers: Set<String> = [
        "AVAudioFile", "AVAudioRecorder", "FileHandle", "NSFileHandle", "FileManager", "NSFileManager",
        "OutputStream", "NSOutputStream", "UserDefaults", "NSUserDefaults", "Process", "NSTask",
        "UserDefaultsPersistence", "KeychainSecretStore", "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate",
        "SecItemDelete", "fopen", "freopen", "fwrite", "creat", "pwrite", "popen", "system", "posix_spawn",
        "posix_spawnp", "execv", "execve", "execl",
    ]
    static let audioCapturePaths: Set<String> = [
        "Sources/IrisMacOS/Runtime/AVAudioEngineCapturer.swift",
        "Sources/IrisMacOS/Runtime/AVAudioEngineCapturer+Math.swift",
    ]

    /// AppKit event payloads and modifier values are permitted in HotkeyEdgeState;
    /// installing monitors or querying the keyboard/permissions is not.
    static let pureTransitionEffects = coreLiveIOIdentifiers.union([
        "Task", "Thread", "DispatchQueue", "NSLock", "URLSession", "ProcessInfo", "Date",
        "ContinuousClock", "SuspendingClock", "DispatchTime", "mach_absolute_time",
        "AppEnvironment", "AppComposition", "SettingsRepository", "UserDefaults", "NSPasteboard",
        "CGEventSource", "GlobalHotkeyMonitor", "AVAudioEngineCapturer", "PermissionsManager", "AVCaptureDevice",
        "AXIsProcessTrusted", "addGlobalMonitorForEvents", "addLocalMonitorForEvents",
    ])
    static let pureTransitionPaths: Set<String> = [
        "Sources/IrisCore/Transcription/TakeLifecycle.swift",
        "Sources/IrisCore/Transcription/HotkeyIntent.swift",
        "Sources/IrisMacOS/Runtime/InputReadiness.swift",
        "Sources/IrisMacOS/Runtime/HotkeyEdgeState.swift",
    ]

    static let previewLiveIOIdentifiers = providerLiveIOIdentifiers.union(audioStorageIdentifiers).union([
        "AppComposition", "AVAudioEngineCapturer", "GlobalHotkeyMonitor", "AppKitHotkeyEvents", "SystemEvents",
        "URLSessionWebSocketTransport", "RewriteChatClient", "SpeechConnectionProbe", "LiveClipboard", "LiveFocus",
        "LiveKeyPosting", "AccessControlTextInserter", "NSPasteboard", "CGEventSource", "AVCaptureDevice",
        "AVCaptureSession", "AXIsProcessTrusted", "AXIsProcessTrustedWithOptions", "LoginItem", "AppRelauncher",
        "MetaVoiceTranscribeClient", "GrokVoiceTranscribeClient", "ApplicationImage",
        "addGlobalMonitorForEvents", "addLocalMonitorForEvents",
    ])

    static func isAudioStorageScope(_ path: String) -> Bool {
        path.hasPrefix("Sources/IrisCore/") || path.hasPrefix("Sources/IrisProviders/")
            || audioCapturePaths.contains(path)
    }

    static func importedModules(in source: String) -> Set<String> {
        Set(
            Harmonize.on(source: source).imports().compactMap { declaration in
                declaration.node.path.first.map { identifierName($0.name) }
            })
    }

    static func identifiers(in source: String) -> Set<String> {
        Set(
            Parser.parse(source: source).tokens(viewMode: .sourceAccurate).compactMap { token in
                if case .identifier = token.tokenKind { return identifierName(token) }
                return nil
            })
    }

    static func hasUncheckedSendable(in source: String) -> Bool {
        !uncheckedTypes(in: source).isEmpty
    }

    static func hasDetachedTask(in source: String) -> Bool {
        !detachedTaskOwners(in: source).isEmpty
    }

    static func detachedTaskOwners(in source: String) -> [String: Int] {
        detachedTaskOwners(in: [source])[0]
    }

    /// Collect aliases once across the selection, then count reference sites per
    /// source. A reference captured as a function value still requires review.
    static func detachedTaskOwners(in sources: [String]) -> [[String: Int]] {
        detachedTaskOwners(in: sources.map { ModuleSource(source: $0, module: nil) })
    }

    struct ModuleSource {
        let source: String
        let module: String?
    }

    static func detachedTaskOwners(in sources: [ModuleSource]) -> [[String: Int]] {
        let trees = sources.map { Parser.parse(source: $0.source) }
        let aliases = TaskAliasVisitor(viewMode: .sourceAccurate)
        for (source, tree) in zip(sources, trees) {
            aliases.currentModule = source.module
            aliases.walk(tree)
        }
        return zip(sources, trees).map { entry in
            let (source, tree) = entry
            let references = DetachedTaskVisitor(aliases: aliases, module: source.module)
            references.walk(tree)
            return references.owners
        }
    }

    struct ClassDeclaration {
        let name: String
        let qualifiedName: String
        let attributes: Set<String>
        let unconditionalAttributes: Set<String>

        var isObservable: Bool { !attributes.isDisjoint(with: ["Observable", "Observation.Observable"]) }
        var isMainActor: Bool {
            !unconditionalAttributes.isDisjoint(with: ["MainActor", "Swift.MainActor", "_Concurrency.MainActor"])
        }
    }

    static func classes(in source: String) -> [ClassDeclaration] {
        let classes = ClassVisitor(viewMode: .sourceAccurate)
        classes.walk(Parser.parse(source: source))
        return classes.declarations
    }

    static func uncheckedTypes(in source: String) -> Set<String> {
        Set(uncheckedTypeCounts(in: source).keys)
    }

    static func uncheckedTypeCounts(in source: String) -> [String: Int] {
        let types = UncheckedTypeVisitor(viewMode: .sourceAccurate)
        types.walk(Parser.parse(source: source))
        return types.counts
    }

    static func nonisolatedUnsafeCounts(in source: String) -> [String: Int] {
        let visitor = NonisolatedUnsafeVisitor(viewMode: .sourceAccurate)
        visitor.walk(Parser.parse(source: source))
        return visitor.counts
    }

    static func scope(of node: some SyntaxProtocol, name: String? = nil) -> String {
        let names = scopeComponents(of: node, name: name)
        return names.isEmpty ? "<global>" : names.joined(separator: ".")
    }

    static func scopeComponents(of node: some SyntaxProtocol, name: String? = nil) -> [String] {
        var names = name.map { [$0] } ?? []
        var parent = node.parent
        while let ancestor = parent {
            if let name = declarationName(in: ancestor) { names.append(name) }
            parent = ancestor.parent
        }
        return Array(names.reversed())
    }

    static func enclosingTypeScope(of node: some SyntaxProtocol) -> String? {
        var parent = node.parent
        while let ancestor = parent {
            if ancestor.is(ClassDeclSyntax.self) || ancestor.is(StructDeclSyntax.self)
                || ancestor.is(EnumDeclSyntax.self) || ancestor.is(ActorDeclSyntax.self)
                || ancestor.is(ExtensionDeclSyntax.self), let name = declarationName(in: ancestor)
            {
                return scope(of: ancestor, name: name)
            }
            parent = ancestor.parent
        }
        return nil
    }

    static func identifierName(_ token: TokenSyntax) -> String {
        Identifier(token)?.name ?? token.text
    }

    /// Generic arguments do not change the name of the nominal type.
    static func typePath(_ type: TypeSyntax) -> [String]? {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return [identifierName(identifier.name)] }
        if let member = type.as(MemberTypeSyntax.self), let base = typePath(member.baseType) {
            return base + [identifierName(member.name)]
        }
        if let attributed = type.as(AttributedTypeSyntax.self) { return typePath(attributed.baseType) }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
            let element = tuple.elements.first, element.firstName == nil
        {
            return typePath(element.type)
        }
        return nil
    }

    static func expressionPath(_ expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return [identifierName(reference.baseName)]
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
            let path = expressionPath(base)
        {
            return path + [identifierName(member.declName.baseName)]
        }
        if let generic = expression.as(GenericSpecializationExprSyntax.self) {
            return expressionPath(generic.expression)
        }
        if let type = expression.as(TypeExprSyntax.self) { return typePath(type.type) }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
            let element = tuple.elements.first, element.label == nil
        {
            return expressionPath(element.expression)
        }
        return nil
    }

    static func attributeNames(in attributes: AttributeListSyntax) -> Set<String> {
        let names = AttributeNameVisitor(viewMode: .sourceAccurate)
        names.walk(attributes)
        return names.names
    }

    static func unconditionalAttributeNames(in attributes: AttributeListSyntax) -> Set<String> {
        Set(
            attributes.compactMap { element in
                guard let attribute = element.as(AttributeSyntax.self) else { return nil }
                return typePath(attribute.attributeName)?.joined(separator: ".")
            })
    }

    private static func declarationName(in node: Syntax) -> String? {
        if let declaration = node.as(ClassDeclSyntax.self) { return identifierName(declaration.name) }
        if let declaration = node.as(StructDeclSyntax.self) { return identifierName(declaration.name) }
        if let declaration = node.as(EnumDeclSyntax.self) { return identifierName(declaration.name) }
        if let declaration = node.as(ActorDeclSyntax.self) { return identifierName(declaration.name) }
        if let declaration = node.as(ProtocolDeclSyntax.self) { return identifierName(declaration.name) }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            return typePath(declaration.extendedType)?.joined(separator: ".")
                ?? declaration.extendedType.tokens(viewMode: .sourceAccurate).map(\.text).joined()
        }
        if let declaration = node.as(FunctionDeclSyntax.self) { return identifierName(declaration.name) }
        if node.is(InitializerDeclSyntax.self) { return "init" }
        return nil
    }
}

private final class DetachedTaskVisitor: SyntaxVisitor {
    var owners: [String: Int] = [:]
    private let aliases: TaskAliasVisitor
    private let module: String?

    init(aliases: TaskAliasVisitor, module: String?) {
        self.aliases = aliases
        self.module = module
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if SourcePolicy.identifierName(node.declName.baseName) == "detached", let base = node.base,
            var path = SourcePolicy.expressionPath(base)
        {
            if path.last == "self" { path.removeLast() }
            if aliases.isTask(path, at: Syntax(node), module: module) {
                owners[SourcePolicy.scope(of: node), default: 0] += 1
            }
        }
        return .visitChildren
    }
}

private final class AttributeNameVisitor: SyntaxVisitor {
    var names: Set<String> = []
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if let path = SourcePolicy.typePath(node.attributeName) { names.insert(path.joined(separator: ".")) }
        return .skipChildren
    }
}

private final class ClassVisitor: SyntaxVisitor {
    var declarations: [SourcePolicy.ClassDeclaration] = []
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SourcePolicy.identifierName(node.name)
        declarations.append(
            .init(
                name: name, qualifiedName: SourcePolicy.scope(of: node, name: name),
                attributes: SourcePolicy.attributeNames(in: node.attributes),
                unconditionalAttributes: SourcePolicy.unconditionalAttributeNames(in: node.attributes)))
        return .visitChildren
    }
}

private final class UncheckedTypeVisitor: SyntaxVisitor {
    var counts: [String: Int] = [:]
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            SourcePolicy.scope(of: node, name: SourcePolicy.identifierName(node.name)),
            inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            SourcePolicy.scope(of: node, name: SourcePolicy.identifierName(node.name)),
            inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            SourcePolicy.scope(of: node, name: SourcePolicy.identifierName(node.name)),
            inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            SourcePolicy.scope(of: node, name: SourcePolicy.identifierName(node.name)),
            inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name =
            SourcePolicy.typePath(node.extendedType)?.joined(separator: ".")
            ?? node.extendedType.tokens(viewMode: .sourceAccurate).map(\.text).joined()
        record(SourcePolicy.scope(of: node, name: name), inheritance: node.inheritanceClause)
        return .visitChildren
    }

    private func record(_ name: String, inheritance: InheritanceClauseSyntax?) {
        if inheritance?.inheritedTypes.contains(where: {
            guard let attributed = $0.type.as(AttributedTypeSyntax.self),
                SourcePolicy.attributeNames(in: attributed.attributes).contains("unchecked"),
                let path = SourcePolicy.typePath(attributed.baseType)
            else { return false }
            return path == ["Sendable"] || path == ["Swift", "Sendable"] || path == ["_Concurrency", "Sendable"]
        }) == true {
            counts[name, default: 0] += 1
        }
    }
}

private final class NonisolatedUnsafeVisitor: SyntaxVisitor {
    var counts: [String: Int] = [:]

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard hasNonisolatedUnsafe(node.modifiers) else { return .visitChildren }
        for binding in node.bindings {
            let name =
                binding.pattern.as(IdentifierPatternSyntax.self).map { SourcePolicy.identifierName($0.identifier) }
                ?? binding.pattern.tokens(viewMode: .sourceAccurate).map(\.text).joined()
            counts[SourcePolicy.scope(of: node, name: name), default: 0] += 1
        }
        return .visitChildren
    }

    private func hasNonisolatedUnsafe(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            SourcePolicy.identifierName(modifier.name) == "nonisolated"
                && modifier.detail.map { SourcePolicy.identifierName($0.detail) } == "unsafe"
        }
    }
}
