import SwiftSyntax

/// Only reviewed nominal spellings, explicit annotations/aliases, simple
/// bindings, and the listed value-producing API shapes are followed. Unknown
/// bindings shadow outer ones; arbitrary return types/data flow are not inferred.
/// Internal to the test module so SelectedIOPolicy's visitors can share these facts.
final class IOTypeFacts: SyntaxVisitor {
    enum Kind: String {
        case data = "Data"
        case text = "String"
        case frame = "PCMFrame"
        case message = "TransportMessage"
        case request = "RewriteHTTPRequest"
        case bitmap = "NSBitmapImageRep"
        case permissions = "PermissionsManager"
        case jsonEncoder = "JSONEncoder"
        case propertyListEncoder = "PropertyListEncoder"
    }

    private struct Binding {
        let declaration: Syntax
        let visibility: Syntax?
        let annotation: TypeSyntax?
        let initializer: ExprSyntax?
        let isAlias: Bool
    }
    private var bindings: [String: [Binding]] = [:]

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name, at: Syntax(node), type: node.initializer.value, initializer: nil, isAlias: true)
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self) {
            record(
                pattern.identifier, at: Syntax(node), type: node.typeAnnotation?.type,
                initializer: node.initializer?.value)
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self), node.initializer != nil {
            record(
                pattern.identifier, at: Syntax(node), type: node.typeAnnotation?.type,
                initializer: node.initializer?.value)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName ?? node.firstName
        if SourcePolicy.identifierName(name) != "_" {
            record(name, at: Syntax(node), type: node.type, initializer: nil)
        }
        return .visitChildren
    }

    func nominalKind(_ path: [String], at node: Syntax, visited: Set<Int> = []) -> Kind? {
        let known: [String: Kind] = [
            "Data": .data, "Foundation.Data": .data, "NSData": .data, "Foundation.NSData": .data,
            "String": .text, "Swift.String": .text, "NSString": .text, "Foundation.NSString": .text,
            "PCMFrame": .frame, "IrisCore.PCMFrame": .frame,
            "TransportMessage": .message, "IrisCore.TransportMessage": .message,
            "RewriteHTTPRequest": .request, "IrisCore.RewriteHTTPRequest": .request,
            "NSBitmapImageRep": .bitmap, "AppKit.NSBitmapImageRep": .bitmap,
            "PermissionsManager": .permissions, "IrisMacOS.PermissionsManager": .permissions,
            "JSONEncoder": .jsonEncoder, "Foundation.JSONEncoder": .jsonEncoder,
            "PropertyListEncoder": .propertyListEncoder, "Foundation.PropertyListEncoder": .propertyListEncoder,
        ]
        if let kind = known[path.joined(separator: ".")] { return kind }
        guard let binding = lookup(path, at: node), binding.isAlias else { return nil }
        return kind(of: binding, visited: visited)
    }

    private func kind(of type: TypeSyntax, at node: Syntax, visited: Set<Int> = []) -> Kind? {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return kind(of: attributed.baseType, at: node, visited: visited)
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return kind(of: optional.wrappedType, at: node, visited: visited)
        }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return kind(of: optional.wrappedType, at: node, visited: visited)
        }
        guard let path = SourcePolicy.typePath(type) else { return nil }
        return nominalKind(path, at: node, visited: visited)
    }

    func kind(of expression: ExprSyntax, visited: Set<Int> = []) -> Kind? {
        if let unwrapped = unwrap(expression) { return kind(of: unwrapped, visited: visited) }
        if expression.is(StringLiteralExprSyntax.self) { return .text }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return callResultKind(call, visited: visited)
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
            let kind = memberValueKind(member, visited: visited)
        {
            return kind
        }
        guard let path = SourcePolicy.expressionPath(expression), let binding = lookup(path, at: Syntax(expression))
        else { return nil }
        return kind(of: binding, visited: visited)
    }

    private func callResultKind(_ call: FunctionCallExprSyntax, visited: Set<Int>) -> Kind? {
        if let kind = constructorKind(call, visited: visited) { return kind }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base else {
            return nil
        }
        let baseKind = kind(of: base, visited: visited)
        if let kind = receiverCallResultKind(call, member: member, baseKind: baseKind) { return kind }
        return staticSerializationResultKind(member)
    }

    private func receiverCallResultKind(
        _ call: FunctionCallExprSyntax, member: MemberAccessExprSyntax, baseKind: Kind?
    ) -> Kind? {
        let name = SourcePolicy.identifierName(member.declName.baseName)
        let labels = call.arguments.map { $0.label.map(SourcePolicy.identifierName) }
        if name == "asData", baseKind == .frame { return .data }
        if name == "data", baseKind == .text, call.arguments.first?.label?.text == "using" { return .data }
        if name == "encode", baseKind == .jsonEncoder || baseKind == .propertyListEncoder { return .data }
        if name == "representation", baseKind == .bitmap, labels == ["using", "properties"] { return .data }
        // This AppKit factory is used by the opt-in PNG preview tool.
        if name == "bitmapImageRepForCachingDisplay", labels == ["in"] { return .bitmap }
        return nil
    }

    private func staticSerializationResultKind(_ member: MemberAccessExprSyntax) -> Kind? {
        guard let base = member.base, let path = SourcePolicy.expressionPath(base) else { return nil }
        guard
            [
                "JSONSerialization", "Foundation.JSONSerialization", "PropertyListSerialization",
                "Foundation.PropertyListSerialization",
            ].contains(path.joined(separator: ".")), SourcePolicy.identifierName(member.declName.baseName) == "data"
        else { return nil }
        return .data
    }

    private func memberValueKind(_ member: MemberAccessExprSyntax, visited: Set<Int>) -> Kind? {
        guard let base = member.base else { return nil }
        let name = SourcePolicy.identifierName(member.declName.baseName)
        let baseKind = kind(of: base, visited: visited)
        if name == "data", baseKind == .message { return .data }
        if name == "body", baseKind == .request { return .data }
        return nil
    }

    func constructorKind(_ call: FunctionCallExprSyntax, visited: Set<Int> = []) -> Kind? {
        var path = SourcePolicy.expressionPath(call.calledExpression)
        if path?.last == "init" { path?.removeLast() }
        if let path, !path.isEmpty { return nominalKind(path, at: Syntax(call), visited: visited) }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil,
            SourcePolicy.identifierName(member.declName.baseName) == "init", let type = contextualType(of: call)
        {
            return kind(of: type, at: Syntax(call), visited: visited)
        }
        return nil
    }

    private func kind(of binding: Binding, visited: Set<Int>) -> Kind? {
        let id = binding.declaration.positionAfterSkippingLeadingTrivia.utf8Offset
        guard !visited.contains(id) else { return nil }
        let visited = visited.union([id])
        if let type = binding.annotation { return kind(of: type, at: binding.declaration, visited: visited) }
        return binding.initializer.flatMap { kind(of: $0, visited: visited) }
    }

    private func unwrap(_ expression: ExprSyntax) -> ExprSyntax? {
        if let optional = expression.as(OptionalChainingExprSyntax.self) { return optional.expression }
        if let force = expression.as(ForceUnwrapExprSyntax.self) { return force.expression }
        if let attempt = expression.as(TryExprSyntax.self) { return attempt.expression }
        if let awaited = expression.as(AwaitExprSyntax.self) { return awaited.expression }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
            let element = tuple.elements.first, element.label == nil
        {
            return element.expression
        }
        return nil
    }

    private func contextualType(of call: FunctionCallExprSyntax) -> TypeSyntax? {
        var parent = call.parent
        var sawReturn = false
        while let ancestor = parent {
            if let binding = ancestor.as(PatternBindingSyntax.self) { return binding.typeAnnotation?.type }
            if let binding = ancestor.as(OptionalBindingConditionSyntax.self) { return binding.typeAnnotation?.type }
            if ancestor.is(ReturnStmtSyntax.self) { sawReturn = true }
            if let function = ancestor.as(FunctionDeclSyntax.self) {
                guard sawReturn || function.body?.statements.count == 1 else { return nil }
                return function.signature.returnClause?.type
            }
            if ancestor.is(LabeledExprSyntax.self) {
                guard let elements = ancestor.parent?.as(LabeledExprListSyntax.self),
                    let tuple = elements.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1,
                    tuple.elements.first?.label == nil
                else { return nil }
            }
            // An outer call or closure changes the contextual type; don't guess.
            if ancestor.is(FunctionCallExprSyntax.self) || ancestor.is(ClosureExprSyntax.self) { return nil }
            parent = ancestor.parent
        }
        return nil
    }

    private func record(
        _ name: TokenSyntax, at node: Syntax, type: TypeSyntax?, initializer: ExprSyntax?, isAlias: Bool = false
    ) {
        var parent = node.parent
        var visibility: Syntax?
        while let ancestor = parent {
            if ancestor.is(CodeBlockSyntax.self) || ancestor.is(ClosureExprSyntax.self)
                || ancestor.is(FunctionDeclSyntax.self) || ancestor.is(InitializerDeclSyntax.self)
                || (node.is(OptionalBindingConditionSyntax.self)
                    && (ancestor.is(IfExprSyntax.self) || ancestor.is(WhileStmtSyntax.self)))
            {
                visibility = ancestor
                break
            }
            parent = ancestor.parent
        }
        let key = SourcePolicy.scope(of: node, name: SourcePolicy.identifierName(name))
        bindings[key, default: []].append(
            Binding(
                declaration: node, visibility: visibility, annotation: type,
                initializer: initializer, isAlias: isAlias))
    }

    private func lookup(_ original: [String], at node: Syntax) -> Binding? {
        var path = original
        if ["self", "Self"].contains(path.first ?? ""), let owner = SourcePolicy.enclosingTypeScope(of: node) {
            path = owner.split(separator: ".").map(String.init) + Array(path.dropFirst())
        }
        let scope = SourcePolicy.scopeComponents(of: node)
        var ancestors: [Syntax] = []
        var parent: Syntax? = node
        while let ancestor = parent {
            ancestors.append(ancestor)
            parent = ancestor.parent
        }
        for count in stride(from: scope.count, through: 0, by: -1) {
            let key = (Array(scope.prefix(count)) + path).joined(separator: ".")
            let visible = bindings[key, default: []].filter { binding in
                guard let visibility = binding.visibility else { return true }
                return ancestors.contains(visibility)
                    && (binding.declaration.is(FunctionParameterSyntax.self)
                        || binding.declaration.positionAfterSkippingLeadingTrivia
                            <= node.positionAfterSkippingLeadingTrivia)
            }
            if let binding = visible.sorted(by: { lhs, rhs in
                let left = lhs.visibility.flatMap { ancestors.firstIndex(of: $0) } ?? Int.max
                let right = rhs.visibility.flatMap { ancestors.firstIndex(of: $0) } ?? Int.max
                if left != right { return left < right }
                return lhs.declaration.positionAfterSkippingLeadingTrivia
                    > rhs.declaration.positionAfterSkippingLeadingTrivia
            }).first {
                return binding
            }
        }
        return nil
    }
}
