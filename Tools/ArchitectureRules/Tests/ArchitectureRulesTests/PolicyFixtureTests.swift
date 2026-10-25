import Harmonize
import Testing

extension ArchitectureRules {

    @Test func importPolicyRecognizesModifiedSelectiveAndConditionalImports() {
        let source = """
            @preconcurrency import Foundation
            public import AppKit
            internal import Foundation
            package import IrisCore
            @_exported import Security
            import struct Foundation.Date
            import class CoreGraphics.CGColor
            import enum Swift.Optional
            import protocol Swift.Sendable
            import typealias Foundation.NSInteger
            import func Darwin.getpid
            import let Dispatch.DISPATCH_QUEUE_PRIORITY_DEFAULT
            import var Darwin.errno
            #if NEVER_ENABLED
            import SwiftUI
            #else
            @testable import IrisProviders
            #endif
            // import AVFoundation
            let documentation = "import Combine"
            """
        #expect(
            SourcePolicy.importedModules(in: source) == [
                "Foundation", "AppKit", "IrisCore", "Security", "CoreGraphics", "Swift", "Darwin", "Dispatch",
                "SwiftUI", "IrisProviders",
            ])
        #expect(SourcePolicy.importedModules(in: "import `Foundation`") == ["Foundation"])
    }

    @Test func referencePolicyFindsQualifiedNamesAndAliasesButNotComments() {
        let source = """
            typealias Clipboard = System.LiveClipboard
            let clipboard: Clipboard = .init()
            // KeychainSecretStore()
            let example = "URLSession.shared"
            """
        let identifiers = SourcePolicy.identifiers(in: source)
        #expect(identifiers.contains("LiveClipboard"))
        #expect(!identifiers.contains("KeychainSecretStore"))
        #expect(!identifiers.contains("URLSession"))
    }

    @Test func concurrencyExceptionsAreInspectedAsSyntax() {
        #expect(SourcePolicy.hasUncheckedSendable(in: "final class Box: @unchecked Sendable {}"))
        #expect(SourcePolicy.hasUncheckedSendable(in: "struct Box: @unchecked Swift.Sendable {}"))
        #expect(SourcePolicy.hasUncheckedSendable(in: "extension Box: @retroactive @unchecked Swift.Sendable {}"))
        #expect(!SourcePolicy.hasUncheckedSendable(in: "let text = \"@unchecked Sendable\""))
        #expect(SourcePolicy.hasDetachedTask(in: "let work = Task.detached { return 1 }"))
        #expect(!SourcePolicy.hasDetachedTask(in: "let text = \"Task.detached {}\""))
    }

    @Test func moduleBoundaryDoesNotDenyUnrelatedSameNamedTypes() {
        // A provider may have a same-named helper; Core's own Error/Phase names
        // are not dependencies. Imports and the target graph are the boundary.
        let core = "import Foundation\nstruct Phase {}\nenum Error {}"
        let provider = "import Foundation\nimport IrisCore\nstruct Phase {}\nenum Error {}"
        #expect(SourcePolicy.importedModules(in: core).isSubset(of: SourcePolicy.coreImportAllowlist))
        #expect(SourcePolicy.importedModules(in: provider).isSubset(of: SourcePolicy.providerImportAllowlist))
        #expect(
            !SourcePolicy.importedModules(in: "import IrisProviders\n" + core)
                .isSubset(of: SourcePolicy.coreImportAllowlist))
        #expect(
            SourcePolicy.importedModules(in: "import IrisCore\n" + core)
                .isSubset(of: SourcePolicy.providerImportAllowlist))
        #expect(
            !SourcePolicy.importedModules(in: "import IrisMacOS\n" + core)
                .isSubset(of: SourcePolicy.providerImportAllowlist))
    }

    @Test func uncheckedPolicyInspectsEachDeclarationIncludingNestedHelpers() {
        let source = """
            struct Safe: Sendable {}
            final class Locked: NSObject, @unchecked Sendable {
                final class Inner: @unchecked Swift.Sendable {}
            }
            enum Legacy: @unchecked Sendable { case value(Any) }
            actor ActorSyntax: @unchecked Sendable {}
            """
        #expect(SourcePolicy.uncheckedTypes(in: source) == ["Locked", "Locked.Inner", "Legacy", "ActorSyntax"])
    }

    @Test func uncheckedPolicyFindsExtensionConformancesAndAdditionalAttributes() {
        let source = """
            struct Extensible {}
            extension Extensible: @unchecked Sendable {}
            struct Namespace { struct Inner {} }
            extension Namespace.Inner:
                @retroactive
                @unchecked
                Swift.Sendable
            {}
            final class Retroactive: NSObject, @unchecked @retroactive Swift.Sendable {}
            extension Namespace {
                final class Helper: NSObject, @unchecked Swift.Sendable {}
            }
            extension Safe: Sendable {}
            extension Unrelated: @unchecked Other.Sendable {}
            // extension Comment: @unchecked Sendable {}
            let text = "extension Literal: @unchecked Sendable {}"
            """
        #expect(
            SourcePolicy.uncheckedTypes(in: source) == [
                "Extensible", "Namespace.Inner", "Retroactive", "Namespace.Helper",
            ])
    }

    @Test func uncheckedPolicyExposesOwnerCollisionsInOverloadedFunctions() {
        let source = """
            struct Owner {
                func work(_ value: Int) { final class Box: @unchecked Sendable {} }
                func work(_ value: String) { final class Box: @unchecked Sendable {} }
            }
            """
        #expect(SourcePolicy.uncheckedTypeCounts(in: source) == ["Owner.work.Box": 2])
    }

    @Test func detachedPolicyCountsEachReferenceAtItsQualifiedOwner() {
        let source = """
            struct Worker {
                func run() {
                    let first = Task . detached { 1 }
                    let second = Swift.Task.detached { 2 }
                    let third = Task<Void, Never>.detached {}
                    let unrelated = AnotherTask.detached {}
                    let example = "Task.detached {}"
                }
                struct Helper { func stop() { Task.detached {} } }
            }
            extension Worker { func resume() { Task.detached {} } }
            """
        #expect(
            SourcePolicy.detachedTaskOwners(in: source) == [
                "Worker.run": 3, "Worker.Helper.stop": 1, "Worker.resume": 1,
            ])
    }

    @Test func detachedPolicyFindsFunctionValuesParenthesesAndConcurrencyQualification() {
        let source = """
            func spawn() {
                let launch = Task.detached
                (Task.detached) {}
                (Task).detached {}
                ((_Concurrency.Task<Void, Never>)).detached {}
                try await Swift.Task<Void, Never>.detached {}.value
                pass(Task.detached(priority:operation:))
                Task<Void, Never>.self.detached {}
                launch {}
                Other.Task.detached {}
                let text = "_Concurrency.Task.detached"
            }
            """
        #expect(SourcePolicy.detachedTaskOwners(in: source) == ["spawn": 7])
    }

    @Test func detachedPolicyResolvesExplicitScopedAndChainedAliases() {
        let source = """
            typealias Work = Swift.Task<Void, Never>
            typealias Forward = (Work)
            typealias Generic<Value: Sendable> = _Concurrency.Task<Value, Never>
            typealias CycleA = CycleB
            typealias CycleB = CycleA
            struct Worker {
                typealias Local = Forward
                static let taskType = Generic<Void>.self
                func run(_ parameter: Forward.Type) {
                    Local.detached {}
                    Self.Local.detached {}
                    Worker.Local.detached {}
                    Generic<Void>.detached {}
                    Self.taskType.detached {}
                    let localType = Local.self
                    localType.detached {}
                    var annotatedType: Forward.Type = makeTaskType()
                    annotatedType.detached {}
                    parameter.detached {}
                    let launch = Forward.detached
                    launch {}
                    CycleA.detached {}
                }
            }
            struct Unrelated {
                typealias Work = AnotherTask
                func run() { Work.detached {} }
            }
            """
        #expect(SourcePolicy.detachedTaskOwners(in: source) == ["Worker.run": 9])
    }

    @Test func detachedPolicyResolvesAliasesAcrossSourcesWithoutLeakingPrivateOrLocalAliases() {
        let sources = [
            """
            typealias Background = Task<Void, Never>
            private typealias PrivateWork = Task<Void, Never>
            func local() {
                typealias LocalWork = Background
                LocalWork.detached {}
            }
            func unrelated() { LocalWork.detached {} }
            """,
            "func spawn() { Background.detached {}; PrivateWork.detached {} }",
        ]
        #expect(SourcePolicy.detachedTaskOwners(in: sources) == [["local": 1], ["spawn": 1]])
    }

    @Test func detachedPolicyResolvesModuleQualifiedAliasesInTheSelection() {
        let sources: [SourcePolicy.ModuleSource] = [
            .init(source: "typealias Background = Swift.Task<Void, Never>", module: "IrisCore"),
            .init(source: "typealias Forward = IrisCore.Background", module: "IrisMacOS"),
            .init(
                source: "func spawn() { IrisCore.Background.detached {}; IrisMacOS.Forward.detached {} }",
                module: "IrisMacOS"),
        ]
        #expect(SourcePolicy.detachedTaskOwners(in: sources) == [[:], [:], ["spawn": 2]])
    }

    @Test func detachedOwnerKeysAreDeterministicForClosuresInitializersAndNestedFunctions() {
        let source = """
            let launch = Task.detached
            struct Worker {
                let pending = { Task.detached {} }()
                init() { Task.detached {} }
                func run() {
                    let closure = { Task.detached {} }
                    func nested() { Task.detached {} }
                }
            }
            extension Worker { func resume() { Task.detached {} } }
            """
        let expected = [
            "<global>": 1, "Worker": 1, "Worker.init": 1, "Worker.run": 1,
            "Worker.run.nested": 1, "Worker.resume": 1,
        ]
        #expect(SourcePolicy.detachedTaskOwners(in: source) == expected)
        #expect(SourcePolicy.detachedTaskOwners(in: source) == expected)
    }

    @Test func detachedPolicyConservativelyReviewsShadowedTaskSpellings() {
        let source = "struct Task { static func detached() {} }; Task.detached()"
        #expect(SourcePolicy.detachedTaskOwners(in: source) == ["<global>": 1])
        #expect(!SourcePolicy.hasDetachedTask(in: "AnotherTask.detached()"))
    }

    @Test func referencePolicyInspectsInterpolationKeyPathsSelectorsAndMacroArguments() {
        let source = #"""
            // UserDefaults
            let literal = "FileManager"
            let interpolation = "request \(URLSession.shared)"
            let keyPath = \Model.FileHandle
            let selector = #selector(Controller.Process)
            let macroArgument = #Review(UserDefaults.standard)
            """#
        let identifiers = SourcePolicy.identifiers(in: source)
        #expect(identifiers.isSuperset(of: ["URLSession", "FileHandle", "Process", "UserDefaults"]))
        #expect(!identifiers.contains("FileManager"))
        #expect(SourcePolicy.identifiers(in: "let x = `URLSession`.shared").contains("URLSession"))
    }

    @Test func schedulingAndClocksAreAllowedInCoreOwnersButForbiddenInPureTransitions() {
        let source = """
            import Foundation
            func ownEffects() {
                let now = ProcessInfo.processInfo.systemUptime
                DispatchQueue.global().async {}
            }
            """
        let identifiers = SourcePolicy.identifiers(in: source)
        #expect(identifiers.isDisjoint(with: SourcePolicy.coreLiveIOIdentifiers))
        #expect(!identifiers.isDisjoint(with: SourcePolicy.pureTransitionEffects))
        #expect(
            !SourcePolicy.identifiers(in: "let clock = Date()").isDisjoint(with: SourcePolicy.pureTransitionEffects))
        #expect(
            SourcePolicy.identifiers(in: "// Task {}; Date()\nlet literal = \"DispatchQueue\"")
                .isDisjoint(with: SourcePolicy.pureTransitionEffects))
    }

    @Test func observableClassesAreDiscoveredWithoutAddingNamesToReviewedRoles() {
        let source = """
            @Observable final class NewController { var value = 0 }
            @MainActor @Observable final class Reviewed { var value = 0 }
            @_Concurrency.MainActor @Observation.Observable final class Qualified { var value = 0 }
            struct Scope { @Observable final class Nested { var value = 0 } }
            @Other.MainActor @Observable final class Impostor { var value = 0 }
            @Observable
            #if DEBUG
            @MainActor
            #endif
            final class Conditional { var value = 0 }
            @Other.Observable final class Unrelated {}
            // @Observable final class Comment {}
            let text = "@Observable final class Literal {}"
            """
        let classes = SourcePolicy.classes(in: source)
        let observable = classes.filter { $0.isObservable }
        #expect(observable.count == 6)
        #expect(
            Set(observable.filter { !$0.isMainActor }.map(\.qualifiedName)) == [
                "NewController", "Scope.Nested", "Impostor", "Conditional",
            ])
        #expect(classes.first { $0.name == "Qualified" }?.isMainActor == true)
    }

    @Test func actorDeclarationGuardDistinguishesAnActorFromASameNamedClass() {
        #expect(Harmonize.on(source: "actor DictationOrchestrator {}").actors().count == 1)
        #expect(Harmonize.on(source: "class DictationOrchestrator {}").actors().isEmpty)
    }

}
