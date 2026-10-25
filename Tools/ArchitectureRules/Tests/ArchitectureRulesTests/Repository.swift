import Foundation
import Harmonize
import Testing
import Yams

/// Harmonize's synchronous AST warm-up uses shared dispatch caches. Serialize
/// architectural tests to avoid nested warm-ups exhausting the dispatch pool.
@Suite(.serialized)
struct ArchitectureRules {}

enum Repository {
    static var root: URL {
        get throws {
            try findRoot(startingAt: URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()) { directory in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
                    && isDirectory(directory.appendingPathComponent("Sources"))
            }
        }
    }

    static func sources(_ folder: String) throws -> [SwiftSourceCode] {
        let root = try Repository.root
        let config = try configurationPath(
            root: root, startingAt: URL(fileURLWithPath: #filePath).resolvingSymlinksInPath(),
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            try validateConfiguration(String(contentsOf: config, encoding: .utf8))
        } catch {
            throw RepositoryInspectionError("Cannot read architecture configuration at \(config.path): \(error)")
        }
        _ = try sourceDirectory(folder, root: root, directoryExists: isDirectory)
        // Preflight the exact path; Harmonize otherwise falls back to a fuzzy
        // folder search, and its config loader uses fatalError/try! on failure.
        // The scope is already beneath Sources. Do not let productionCode()
        // silently hide production folders ending in Tests or Fixtures.
        let sources = Harmonize.productionAndTestCode(#filePath).on(folder).sources()
        try #require(!sources.isEmpty, "Architecture scope matched no sources: \(folder)")
        return sources.sorted { ($0.filePath?.path ?? "") < ($1.filePath?.path ?? "") }
    }

    static func relativePath(_ source: SwiftSourceCode) throws -> String {
        guard let path = source.filePath else {
            throw RepositoryInspectionError("Architecture selection contains a source without a file path")
        }
        return try relativePath(path.resolvingSymlinksInPath(), under: root)
    }

    static func declaredDependencies() throws -> [String: Set<String>] {
        let root = try Repository.root
        guard
            let toolPackage = ancestor(
                startingAt: URL(fileURLWithPath: #filePath),
                matching: {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path)
                })
        else {
            throw RepositoryInspectionError("Cannot locate the architecture test package for manifest inspection")
        }
        // Do not acquire the application's .build lock from inside the test
        // runner. A unique, tool-owned scratch path also isolates parallel runs.
        let scratch = toolPackage.appendingPathComponent(".build/manifest-inspection/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let arguments = manifestArguments(root: root, scratch: scratch)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // stderr is inherited, not an unread pipe. SwiftPM/toolchain diagnostics
        // remain visible in the test output without contaminating JSON stdout.
        process.standardError = FileHandle.standardError
        do { try process.run() } catch {
            throw RepositoryInspectionError("Cannot launch \(arguments.joined(separator: " ")): \(error)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw RepositoryInspectionError(
                "Manifest inspection failed (status \(process.terminationStatus)); see inherited stderr. "
                    + "Command: \(arguments.joined(separator: " ")). "
                    + "Scratch is isolated from the application's .build; stop conflicting SwiftPM commands before retrying."
            )
        }
        return try declaredDependencies(from: data)
    }

    static func manifestArguments(root: URL, scratch: URL) -> [String] {
        [
            "swift", "package", "dump-package", "--package-path", root.path,
            "--scratch-path", scratch.path, "--manifest-cache", "local",
        ]
    }

    static func declaredDependencies(from data: Data) throws -> [String: Set<String>] {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch {
            let stdout = String(data: data.prefix(2000), encoding: .utf8) ?? "<stdout is not valid UTF-8>"
            throw RepositoryInspectionError(
                "dump-package did not produce valid JSON; see inherited stderr. stdout: \(stdout). Error: \(error)")
        }
        guard let manifest = json as? [String: Any], let targets = manifest["targets"] as? [[String: Any]],
            !targets.isEmpty
        else { throw RepositoryInspectionError("dump-package JSON must contain a nonempty targets array") }
        var graph: [String: Set<String>] = [:]
        for target in targets {
            guard let name = target["name"] as? String, !name.isEmpty, graph[name] == nil,
                let dependencies = target["dependencies"] as? [[String: Any]]
            else { throw RepositoryInspectionError("Malformed or duplicate target in dump-package JSON: \(target)") }
            graph[name] = Set(try dependencies.map { try dependencyName($0, target: name) })
        }
        return graph
    }

    private static func dependencyName(_ dependency: [String: Any], target: String) throws -> String {
        guard dependency["product"] == nil else {
            throw RepositoryInspectionError("External product dependency in application package target: \(target)")
        }
        let keys = ["byName", "target"].filter { dependency[$0] != nil }
        guard keys.count == 1, let key = keys.first, let fields = dependency[key] as? [Any],
            let name = fields.first as? String, !name.isEmpty
        else { throw RepositoryInspectionError("Unknown dependency shape for \(target): \(dependency)") }
        return name
    }

    /// Walk from the source file, independent of its nesting depth or cwd.
    static func findRoot(startingAt file: URL, isRoot: (URL) -> Bool) throws -> URL {
        guard let root = ancestor(startingAt: file, matching: isRoot) else {
            throw RepositoryInspectionError(
                "Cannot locate an application Package.swift + Sources directory above \(file.path)")
        }
        return root
    }

    static func configurationPath(root: URL, startingAt file: URL, exists: (URL) -> Bool) throws -> URL {
        let expected = root.appendingPathComponent(".harmonize.yaml")
        guard exists(expected) else {
            throw RepositoryInspectionError("Missing architecture configuration: \(expected.path)")
        }
        let nearest = ancestor(startingAt: file) { exists($0.appendingPathComponent(".harmonize.yaml")) }
        guard nearest?.standardizedFileURL.pathComponents == root.standardizedFileURL.pathComponents else {
            throw RepositoryInspectionError(
                "A nearer .harmonize.yaml would redirect Harmonize's scan; expected only \(expected.path)")
        }
        return expected
    }

    static func validateConfiguration(_ yaml: String) throws {
        struct Configuration: Decodable { let excludes: [String] }
        do { _ = try YAMLDecoder().decode(Configuration.self, from: yaml) } catch {
            throw RepositoryInspectionError("Invalid .harmonize.yaml; expected an excludes array of strings: \(error)")
        }
    }

    static func sourceDirectory(_ folder: String, root: URL, directoryExists: (URL) -> Bool) throws -> URL {
        let directory = root.appendingPathComponent(folder).standardizedFileURL
        let sources = root.appendingPathComponent("Sources").standardizedFileURL
        guard !folder.hasPrefix("/"), directory.pathComponents.starts(with: sources.pathComponents),
            directoryExists(directory)
        else {
            throw RepositoryInspectionError(
                "Architecture scope is not an existing directory beneath Sources: \(folder) (root: \(root.path))")
        }
        return directory
    }

    static func relativePath(_ file: URL, under root: URL) throws -> String {
        let components = file.standardizedFileURL.pathComponents
        let prefix = root.standardizedFileURL.pathComponents
        guard components.starts(with: prefix), components.count > prefix.count else {
            throw RepositoryInspectionError("Source \(file.path) is not beneath repository root \(root.path)")
        }
        return components.dropFirst(prefix.count).joined(separator: "/")
    }

    private static func ancestor(startingAt file: URL, matching predicate: (URL) -> Bool) -> URL? {
        var directory = file.standardizedFileURL.deletingLastPathComponent()
        while true {
            if predicate(directory) { return directory }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { return nil }
            directory = parent
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

struct RepositoryInspectionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
