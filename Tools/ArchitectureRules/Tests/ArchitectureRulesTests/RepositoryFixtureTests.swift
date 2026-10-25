import Foundation
import Testing

extension ArchitectureRules {

    @Test func repositoryRootDiscoveryDoesNotDependOnTestFileDepth() throws {
        let root = URL(fileURLWithPath: "/workspace/iris", isDirectory: true)
        let files = [
            "Tools/ArchitectureRules/Tests/ArchitectureRulesTests/Repository.swift",
            "Tools/ArchitectureRules/Tests/ArchitectureRulesTests/Helpers/Nested/Repository.swift",
        ]
        for path in files {
            #expect(
                try Repository.findRoot(startingAt: root.appendingPathComponent(path), isRoot: { $0 == root }) == root)
        }
        #expect(throws: RepositoryInspectionError.self) {
            try Repository.findRoot(startingAt: root.appendingPathComponent(files[0]), isRoot: { _ in false })
        }
    }

    @Test func configurationPreflightRejectsMissingOrNearerConfiguration() throws {
        let root = URL(fileURLWithPath: "/workspace/iris", isDirectory: true)
        let file = root.appendingPathComponent("Tools/ArchitectureRules/Tests/Nested/Repository.swift")
        let expected = root.appendingPathComponent(".harmonize.yaml")
        #expect(try Repository.configurationPath(root: root, startingAt: file, exists: { $0 == expected }) == expected)
        #expect(throws: RepositoryInspectionError.self) {
            try Repository.configurationPath(root: root, startingAt: file, exists: { _ in false })
        }
        let nearer = root.appendingPathComponent("Tools/ArchitectureRules/.harmonize.yaml")
        #expect(throws: RepositoryInspectionError.self) {
            try Repository.configurationPath(root: root, startingAt: file, exists: { $0 == expected || $0 == nearer })
        }
    }

    @Test func configurationPreflightUsesYAMLAndRejectsMalformedOrMistypedExcludes() throws {
        try Repository.validateConfiguration("# comment\nexcludes: [.build, Iris.app, dist, Package.swift]\n")
        for yaml in ["excludes: [", "excludes: .build", "exclude: [.build]", ""] {
            #expect(throws: RepositoryInspectionError.self) { try Repository.validateConfiguration(yaml) }
        }
    }

    @Test func relativePathsStripOnlyRepositoryPathComponents() throws {
        let root = URL(fileURLWithPath: "/workspace/iris", isDirectory: true)
        #expect(
            try Repository.relativePath(root.appendingPathComponent("Sources/IrisCore/File.swift"), under: root)
                == "Sources/IrisCore/File.swift")
        #expect(
            try Repository.relativePath(root.appendingPathComponent("workspace/iris/File.swift"), under: root)
                == "workspace/iris/File.swift")
        #expect(throws: RepositoryInspectionError.self) {
            try Repository.relativePath(URL(fileURLWithPath: "/workspace/iris-other/File.swift"), under: root)
        }
    }

    @Test func sourceSelectionsMustExistAndCannotEscapeSources() throws {
        let root = URL(fileURLWithPath: "/workspace/iris", isDirectory: true)
        let expected = root.appendingPathComponent("Sources/IrisCore", isDirectory: true)
        #expect(
            try Repository.sourceDirectory(
                "Sources/IrisCore", root: root, directoryExists: { $0.path == expected.path }
            )
            .path == expected.path)
        for folder in ["Tests", "Sources/../Tests", "/Sources/IrisCore", "Sources/IrisCoreMissing"] {
            #expect(throws: RepositoryInspectionError.self) {
                try Repository.sourceDirectory(folder, root: root, directoryExists: { $0.path == expected.path })
            }
        }
    }

    @Test func manifestInvocationUsesAnExplicitIsolatedScratchAndLocalCache() {
        let root = URL(fileURLWithPath: "/workspace/iris", isDirectory: true)
        let scratch = root.appendingPathComponent("Tools/ArchitectureRules/.build/manifest-inspection/fixture")
        #expect(
            Repository.manifestArguments(root: root, scratch: scratch) == [
                "swift", "package", "dump-package", "--package-path", root.path,
                "--scratch-path", scratch.path, "--manifest-cache", "local",
            ])
    }

    @Test func manifestDependenciesAcceptByNameAndTargetShapesIncludingConditions() throws {
        let data = Data(
            #"""
            {"targets": [
              {"name": "IrisCore", "dependencies": []},
              {"name": "IrisProviders", "dependencies": [{"byName": ["IrisCore", null]}]},
              {"name": "IrisMacOS", "dependencies": [
                {"target": ["IrisCore", {"platformNames": ["macos"]}]},
                {"byName": ["IrisProviders", null]}
              ]}
            ]}
            """#.utf8)
        #expect(
            try Repository.declaredDependencies(from: data) == [
                "IrisCore": [], "IrisProviders": ["IrisCore"], "IrisMacOS": ["IrisCore", "IrisProviders"],
            ])
    }

    @Test func manifestDependenciesRejectProductsUnknownShapesAndMalformedOutput() {
        let invalidJSON = [
            #"{"targets": [{"name": "IrisCore", "dependencies": [{"product": ["External", "package", null]}]}]}"#,
            #"{"targets": [{"name": "IrisCoreTests", "dependencies": [{"product": ["External", "package", null]}]}]}"#,
            #"{"targets": [{"name": "IrisCore", "dependencies": [{"unknown": ["IrisProviders"]}]}]}"#,
            #"{"targets": [{"name": "IrisCore", "dependencies": null}]}"#,
            #"{"targets": [{"name": "IrisCore", "dependencies": []}, {"name": "IrisCore", "dependencies": []}]}"#,
            #"{"targets": []}"#,
            "Another instance of SwiftPM is already running...",
        ]
        for json in invalidJSON {
            #expect(throws: RepositoryInspectionError.self) {
                try Repository.declaredDependencies(from: Data(json.utf8))
            }
        }
    }

}
