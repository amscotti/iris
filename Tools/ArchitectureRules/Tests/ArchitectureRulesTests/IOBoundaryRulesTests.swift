import Foundation
import Harmonize
import Testing

extension ArchitectureRules {

    @Test func providersDoNotReferenceSelectedLiveIOAPIs() throws {
        for source in try Repository.sources("Sources/IrisProviders") {
            let references =
                SourcePolicy.identifierReferences(
                    in: source.source, matching: SourcePolicy.providerLiveIOIdentifiers)
                + SourcePolicy.selectedFileIOReferences(in: source.source)
            let path = try Repository.relativePath(source)
            #expect(
                references.isEmpty,
                "Provider I/O uses ByteStream/request ports, not selected live APIs: \(path): \(references.map(\.key))")
        }
    }

    @Test func audioPipelineDoesNotReferenceSelectedStorageAPIs() throws {
        let sources = try Repository.sources("Sources").filter {
            SourcePolicy.isAudioStorageScope(try Repository.relativePath($0))
        }
        let paths = Set(try sources.map(Repository.relativePath))
        try #require(SourcePolicy.audioCapturePaths.isSubset(of: paths), "The reviewed capturer must be inspected")
        try #require(paths.contains { $0.hasPrefix("Sources/IrisCore/") })
        try #require(paths.contains { $0.hasPrefix("Sources/IrisProviders/") })
        for source in sources {
            let references =
                SourcePolicy.identifierReferences(
                    in: source.source, matching: SourcePolicy.audioStorageIdentifiers)
                + SourcePolicy.selectedFileIOReferences(in: source.source)
            let path = try Repository.relativePath(source)
            #expect(
                references.isEmpty,
                "Selected direct storage/process APIs are forbidden in the audio scope: \(path): \(references.map(\.key))"
            )
        }
    }

    @Test func previewAssemblyDoesNotReferenceSelectedLiveIOAdapters() throws {
        var reviewed: [String: Int] = [:]
        for source in try Repository.sources("Sources/IrisMacOS/App/Preview") {
            let path = try Repository.relativePath(source)
            for reference in SourcePolicy.previewIOReferences(in: source.source) {
                let key = path + "#" + reference.key
                if SourcePolicy.previewIOExceptions[key] != nil {
                    reviewed[key, default: 0] += 1
                } else {
                    Issue.record(
                        "Preview must use offline ports/snapshot permissions; selected live I/O reference: \(key)")
                }
            }
        }
        #expect(
            reviewed == SourcePolicy.previewIOExceptions.mapValues(\.count),
            "New, moved, duplicated, or stale preview developer-output exceptions require owner/API review")
        #expect(
            SourcePolicy.previewIOExceptions.values.allSatisfy { exception in
                let referenceCount = exception.count
                return referenceCount > 0 && !exception.reason.isEmpty
            })
    }

}
