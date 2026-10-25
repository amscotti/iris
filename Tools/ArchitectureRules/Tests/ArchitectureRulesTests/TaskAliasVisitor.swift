import SwiftSyntax

/// Resolve explicit typealiases, annotated metatypes, and immutable `.self` bindings.
/// This is conservative syntax lookup, not compiler name/type resolution.
final class TaskAliasVisitor: SyntaxVisitor {
    private struct Alias {
        let declaration: Syntax
        let target: [String]
        let visibilityScope: Syntax?
        let module: String?

        func isVisible(from node: Syntax) -> Bool {
            guard let visibilityScope else { return true }
            var parent: Syntax? = node
            while let ancestor = parent {
                if ancestor == visibilityScope { return true }
                parent = ancestor.parent
            }
            return false
        }
    }

    private var declarations: [String: [Alias]] = [:]
    var currentModule: String?

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let type = node.initializer.value
        if let target = metatypeTarget(type) ?? SourcePolicy.typePath(type) {
            record(name: node.name, target: target, node: Syntax(node), modifiers: node.modifiers)
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            if let annotation = binding.typeAnnotation, let target = metatypeTarget(annotation.type) {
                record(name: pattern.identifier, target: target, node: Syntax(node), modifiers: node.modifiers)
            } else if node.bindingSpecifier.tokenKind == .keyword(.let), let initializer = binding.initializer,
                var target = SourcePolicy.expressionPath(initializer.value), target.last == "self"
            {
                target.removeLast()
                record(name: pattern.identifier, target: target, node: Syntax(node), modifiers: node.modifiers)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName ?? node.firstName
        if SourcePolicy.identifierName(name) != "_", let target = metatypeTarget(node.type) {
            record(name: name, target: target, node: Syntax(node), modifiers: [])
        }
        return .visitChildren
    }

    private func metatypeTarget(_ type: TypeSyntax) -> [String]? {
        if let attributed = type.as(AttributedTypeSyntax.self) { return metatypeTarget(attributed.baseType) }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
            let element = tuple.elements.first, element.firstName == nil
        {
            return metatypeTarget(element.type)
        }
        guard let metatype = type.as(MetatypeTypeSyntax.self), metatype.metatypeSpecifier.text == "Type" else {
            return nil
        }
        return SourcePolicy.typePath(metatype.baseType)
    }

    func isTask(_ path: [String], at node: Syntax, module: String?, visited: Set<String> = []) -> Bool {
        if path == ["Task"] || path == ["Swift", "Task"] || path == ["_Concurrency", "Task"] { return true }
        var path = path
        if ["self", "Self"].contains(path.first ?? ""), let owner = SourcePolicy.enclosingTypeScope(of: node) {
            path = [owner] + Array(path.dropFirst())
        }
        let scope = SourcePolicy.scopeComponents(of: node)
        for count in stride(from: scope.count, through: 0, by: -1) {
            let key = (Array(scope.prefix(count)) + path).joined(separator: ".")
            let names = module.map { [$0 + "." + key, key] } ?? [key]
            for name in names {
                let candidates = declarations[name, default: []].filter { $0.isVisible(from: node) }
                if !candidates.isEmpty {
                    guard !visited.contains(name) else { return false }
                    return candidates.contains {
                        isTask($0.target, at: $0.declaration, module: $0.module, visited: visited.union([name]))
                    }
                }
            }
        }
        return false
    }

    private func record(name: TokenSyntax, target: [String], node: Syntax, modifiers: DeclModifierListSyntax) {
        var parent = node.parent
        var visibilityScope: Syntax?
        let isFilePrivate = modifiers.contains { ["private", "fileprivate"].contains($0.name.text) }
        while let ancestor = parent {
            if ancestor.is(CodeBlockSyntax.self) || ancestor.is(FunctionDeclSyntax.self)
                || (isFilePrivate && ancestor.is(SourceFileSyntax.self))
            {
                visibilityScope = ancestor
                break
            }
            parent = ancestor.parent
        }
        let key = SourcePolicy.scope(of: node, name: SourcePolicy.identifierName(name))
        let alias = Alias(declaration: node, target: target, visibilityScope: visibilityScope, module: currentModule)
        declarations[key, default: []].append(alias)
        if let module = currentModule { declarations[module + "." + key, default: []].append(alias) }
    }
}
