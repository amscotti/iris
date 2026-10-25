import Foundation
import Harmonize
import Testing

/// Exceptions are scoped by declaration and file, with an explicit safety argument.
private let uncheckedExceptions: [String: String] = [
    "Sources/IrisCore/Config/SettingsRepository.swift#SettingsRepository":
        "Repository state and persistence access are lock-serialized",
    "Sources/IrisCore/Transcription/AsyncResult.swift#AsyncResult": "Continuation/result latch protected by NSLock",
    "Sources/IrisCore/Transcription/AsyncDeadline.swift#DeadlineRace":
        "Race settlement and owned tasks protected by NSLock",
    "Sources/IrisCore/Transcription/StateBroadcast.swift#StateBroadcast": "Subscriber registry protected by NSLock",
    "Sources/IrisProviders/Mock/MockTranscriptionClient.swift#MockTranscriptionClient":
        "Offline fixture state protected by NSLock",
    "Sources/IrisMacOS/Adapters/SystemEvents.swift#SystemEvents.ObserverTokens":
        "Main-actor setup; thread-safe token/task teardown",
    "Sources/IrisMacOS/Adapters/PermissionsManager.swift#PermissionsManager.ResetProcessBox":
        "Single owned reset process passed to its worker",
    "Sources/IrisMacOS/Adapters/PermissionsManager.swift#PermissionsManager.ResetWaiter":
        "Termination/timeout latch protected by NSLock",
    "Sources/IrisMacOS/Adapters/Persistence.swift#UserDefaultsPersistence":
        "UserDefaults is thread-safe; repository serializes writes",
    "Sources/IrisMacOS/Adapters/Persistence.swift#KeychainSecretStore": "Keychain writes protected by NSLock",
    "Sources/IrisMacOS/Runtime/PressState.swift#PressConfigurationBox": "Settings snapshot protected by NSLock",
    "Sources/IrisMacOS/Runtime/PressState.swift#PermissionSnapshot": "Permission mirror protected by NSLock",
    "Sources/IrisMacOS/Runtime/ClipboardAccess.swift#ClipboardAccess":
        "AppKit access protected by bounded semaphore lease",
    "Sources/IrisMacOS/Runtime/WebSocketTransport.swift#URLSessionWebSocketTransport":
        "Socket/task ownership protected by NSLock",
    "Sources/IrisMacOS/Runtime/TextInserter.swift#AccessControlTextInserter":
        "Configuration/handler lock; insertion runs on owned blocking worker",
    "Sources/IrisMacOS/Runtime/TextInserter.swift#AccessControlTextInserter.snapshotWithinBudget.Box":
        "Snapshot result published only after semaphore completion",
    "Sources/IrisMacOS/Runtime/RestartableStream.swift#RestartableStream": "Stream generation protected by NSLock",
    "Sources/IrisMacOS/Runtime/PressTimelineLog.swift#PressTimelineLog": "Timing state protected by NSLock",
    "Sources/IrisMacOS/Runtime/AVAudioEngineCapturer+Math.swift#AVAudioEngineCapturer.SingleUseInput":
        "Converter invokes buffer supply synchronously on one thread",
    "Sources/IrisMacOS/Runtime/AVAudioEngineCapturer+Math.swift#AVAudioEngineCapturer.NativeChunkPool":
        "Free list and native-input heartbeat protected by NSLock; acquired storage has one owner until released",
    "Sources/IrisMacOS/UI/Pill/PillController.swift#NotificationCleanupToken":
        "Setup on main actor; thread-safe observer teardown",
    "Sources/IrisMacOS/UI/Settings/SettingsWindowController.swift#SettingsObserverTokens":
        "Main-actor setup; thread-safe observer teardown",
    "Sources/IrisMacOS/App/Preview/SettingsPreview.swift#PreviewSettingsStore":
        "In-memory preview store protected by NSLock",
]

private let nonisolatedUnsafeExceptions: [String: String] = [
    "Sources/IrisMacOS/Runtime/AVAudioEngineCapturer.swift#AVAudioEngineCapturer.captureFailureHandler":
        "Handler access protected by captureFailureLock"
]

extension ArchitectureRules {

    @Test func uncheckedSendableExceptionsStayNarrowAndReviewed() throws {
        let sources = try Repository.sources("Sources")
        let actual = try sources.reduce(into: Set<String>()) { result, source in
            for (name, count) in SourcePolicy.uncheckedTypeCounts(in: source.source) {
                let key = try Repository.relativePath(source) + "#" + name
                #expect(count == 1, "Unchecked declaration key must be unique: \(key)")
                result.insert(key)
            }
        }
        #expect(actual == Set(uncheckedExceptions.keys), "New or stale unchecked Sendable exceptions require review")
        #expect(uncheckedExceptions.values.allSatisfy { !$0.isEmpty })
    }

    @Test func nonisolatedUnsafeExceptionsStayNarrowAndReviewed() throws {
        let sources = try Repository.sources("Sources")
        let actual = try sources.reduce(into: Set<String>()) { result, source in
            for (name, count) in SourcePolicy.nonisolatedUnsafeCounts(in: source.source) {
                let key = try Repository.relativePath(source) + "#" + name
                #expect(count == 1, "nonisolated(unsafe) declaration key must be unique: \(key)")
                result.insert(key)
            }
        }
        #expect(
            actual == Set(nonisolatedUnsafeExceptions.keys),
            "New or stale nonisolated(unsafe) exceptions require review")
        #expect(nonisolatedUnsafeExceptions.values.allSatisfy { !$0.isEmpty })
    }

    @Test func detachedTaskBoundariesStayExplicit() throws {
        let expected: [String: Int] = [
            // The continuation race owns and cancels its worker and timer.
            "Sources/IrisCore/Transcription/AsyncDeadline.swift#AsyncDeadline.run": 2,
            // runTask is cancelled and joined through the bounded runtime cleanup.
            "Sources/IrisMacOS/Runtime/DictationRuntime.swift#DictationRuntime.reconcile": 1,
            // The caller awaits the worker; each subprocess has its own deadline.
            "Sources/IrisMacOS/Adapters/PermissionsManager.swift#PermissionsManager.resetPermissionState": 1,
            // The one-shot waiter stores and cancels its timeout task.
            "Sources/IrisMacOS/Adapters/PermissionsManager.swift#PermissionsManager.ResetWaiter.armTimeout": 1,
            // AX target resolution is stored on the take and cancelled with it.
            "Sources/IrisCore/Transcription/DictationOrchestrator+Processing.swift#DictationOrchestrator.resolveTarget":
                1,
            // The caller awaits the SecItem work; the store serializes writes.
            "Sources/IrisMacOS/Adapters/Persistence.swift#KeychainSecretStore.runOffMain": 1,
        ]
        let sources = try Repository.sources("Sources")
        let policySources = try sources.map { source in
            let path = try Repository.relativePath(source).split(separator: "/")
            let module = path.count > 2 ? String(path[1]) : nil
            return SourcePolicy.ModuleSource(source: source.source, module: module)
        }
        let owners = SourcePolicy.detachedTaskOwners(in: policySources)
        var actual: [String: Int] = [:]
        for (source, references) in zip(sources, owners) {
            for (owner, count) in references {
                actual[try Repository.relativePath(source) + "#" + owner] = count
            }
        }
        #expect(
            actual == expected,
            "New or stale detached reference sites require owner/teardown review, even in approved files"
        )
    }

    @Test func pureTransitionsDoNotAcquireResourcesOrLaunchWork() throws {
        let paths = SourcePolicy.pureTransitionPaths
        let sources = try Repository.sources("Sources").filter { paths.contains(try Repository.relativePath($0)) }
        try #require(Set(try sources.map(Repository.relativePath)) == paths)
        sources.assertTrue(message: "Transitions return decisions; their owners supply time and perform effects") {
            SourcePolicy.identifiers(in: $0.source).isDisjoint(with: SourcePolicy.pureTransitionEffects)
        }
    }

}
