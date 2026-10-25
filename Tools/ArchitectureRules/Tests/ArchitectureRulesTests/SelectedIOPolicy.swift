import SwiftParser
import SwiftSyntax

extension SourcePolicy {
    struct IOReference: Sendable, Equatable {
        let owner: String
        let api: String

        var key: String { owner + "#" + api }
    }

    struct ReviewedIOException: Sendable {
        let count: Int
        let reason: String
    }

    /// Developer-only screenshots/report and one code-signature diagnostic.
    /// No entire preview file, directory, or adapter is exempted.
    static let previewIOExceptions: [String: ReviewedIOException] = [
        "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift#SettingsPreview.capture#FileManager":
            .init(count: 1, reason: "Create the explicitly requested preview-output directory"),
        "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift#SettingsPreview.capture#Data.write":
            .init(count: 1, reason: "Write the preview lifecycle metadata report, not runtime audio or transcripts"),
        "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift#SettingsPreview.snapshot#Data.write":
            .init(count: 1, reason: "Write a PNG rendered from the offline preview window"),
        "Sources/IrisMacOS/App/Preview/SettingsPreviewCapture.swift#SettingsPreview.capture#ApplicationImage":
            .init(count: 1, reason: "Record a code-signature Boolean in the developer lifecycle report"),
    ]

    static func identifierReferences(in source: String, matching names: Set<String>) -> [IOReference] {
        Parser.parse(source: source).tokens(viewMode: .sourceAccurate).compactMap { token in
            guard case .identifier = token.tokenKind else { return nil }
            let name = identifierName(token)
            guard names.contains(name) else { return nil }
            return IOReference(owner: scope(of: token), api: name)
        }
    }

    /// Obvious Foundation file operations, including typed/inferred Data.write
    /// receivers. This small, file-local syntax lookup is not Swift type checking.
    static func selectedFileIOReferences(in source: String) -> [IOReference] {
        let tree = Parser.parse(source: source)
        let types = IOTypeFacts(viewMode: .sourceAccurate)
        types.walk(tree)
        let references = FileIOVisitor(types: types)
        references.walk(tree)
        return references.references
    }

    static func previewIOReferences(in source: String) -> [IOReference] {
        let tree = Parser.parse(source: source)
        let types = IOTypeFacts(viewMode: .sourceAccurate)
        types.walk(tree)
        let permissions = PreviewPermissionVisitor(types: types)
        permissions.walk(tree)
        return identifierReferences(in: source, matching: previewLiveIOIdentifiers)
            + selectedFileIOReferences(in: source) + permissions.references
    }
}

private final class FileIOVisitor: SyntaxVisitor {
    var references: [SourcePolicy.IOReference] = []
    private let types: IOTypeFacts

    init(types: IOTypeFacts) {
        self.types = types
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if SourcePolicy.identifierName(node.declName.baseName) == "write", let base = node.base,
            let kind = types.kind(of: base), kind == .data || kind == .text
        {
            // Includes captured function values, not only immediate calls.
            references.append(.init(owner: SourcePolicy.scope(of: node), api: kind.rawValue + ".write"))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let kind = types.constructorKind(node), kind == .data || kind == .text,
            let label = node.arguments.first?.label.map(SourcePolicy.identifierName),
            ["contentsOf", "contentsOfFile", "contentsOfURL"].contains(label)
        {
            references.append(.init(owner: SourcePolicy.scope(of: node), api: kind.rawValue + ".init(" + label + ":)"))
        }
        return .visitChildren
    }
}

private final class PreviewPermissionVisitor: SyntaxVisitor {
    var references: [SourcePolicy.IOReference] = []
    private let types: IOTypeFacts

    init(types: IOTypeFacts) {
        self.types = types
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if types.constructorKind(node) == .permissions {
            let labels = node.arguments.map { $0.label.map(SourcePolicy.identifierName) }
            if labels != ["microphoneStatus", "accessibilityGranted"] || node.trailingClosure != nil
                || !node.additionalTrailingClosures.isEmpty
            {
                references.append(.init(owner: SourcePolicy.scope(of: node), api: "PermissionsManager.liveInitializer"))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // A member's declName is not an independent unqualified expression.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName == node { return .visitChildren }
        inspect(ExprSyntax(node))
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        inspect(ExprSyntax(node))
        return .visitChildren
    }

    private func inspect(_ expression: ExprSyntax) {
        guard let path = SourcePolicy.expressionPath(expression),
            types.nominalKind(path, at: Syntax(expression)) == .permissions
        else { return }
        var parent = expression.parent
        while let ancestor = parent {
            if let call = ancestor.as(FunctionCallExprSyntax.self) {
                let callee = call.calledExpression
                if callee.position <= expression.position, callee.endPosition >= expression.endPosition,
                    types.constructorKind(call) == .permissions
                {
                    return
                }
                break
            }
            parent = ancestor.parent
        }
        // Uncalled constructors/metatypes/static references have no safe
        // supplied-snapshot argument list to inspect. Do not silently allow them.
        references.append(.init(owner: SourcePolicy.scope(of: expression), api: "PermissionsManager.factoryReference"))
    }
}
