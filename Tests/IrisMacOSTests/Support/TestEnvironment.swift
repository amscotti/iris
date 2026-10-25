import Foundation
import IrisCore
import IrisProviders

@testable import IrisMacOS

/// Each test owns its stores. Relaunch tests reuse this fixture, never the
/// developer's defaults or Keychain (including asynchronous settings work).
@MainActor
struct TestEnvironment {
    let persistence = TestSettingsStore()
    let secrets = TestSecretStore()

    func make(
        secretStore: (any SecretStoring)? = nil, connections: ProviderConnections? = nil,
        registry: ProviderRegistry = AppProviderAssembly.defaultRegistry(), permissions: PermissionsManager? = nil,
        hotkey: GlobalHotkeyMonitor? = nil, runtimePorts: DictationRuntimePorts? = nil,
        clipboard: any ClipboardPort = FakeClipboard(), defaults: AppSettings = .defaults
    ) -> AppEnvironment {
        let permissions = permissions ?? PermissionsManager(microphoneStatus: .denied, accessibilityGranted: false)
        let ports =
            runtimePorts
            ?? RuntimeFixture().ports(
                microphone: permissions.microphoneGranted, accessibility: permissions.accessibilityGranted,
                hotkey: hotkey)
        return AppEnvironment(
            persistence: persistence,
            secrets: secretStore ?? secrets,
            registry: registry,
            permissions: permissions,
            runtimePorts: ports,
            connections: connections
                ?? ProviderConnections(probe: { _ in
                    throw TranscriptionError(kind: .network, message: "No live network in unit tests.")
                }), clipboard: clipboard, defaults: defaults)
    }
}

final class TestSettingsStore: PersistenceProviding, @unchecked Sendable {
    enum Failure: Error { case read, write }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var readsFail = false
    private var writesFail = false

    var failReads: Bool {
        get { lock.withLock { readsFail } }
        set { lock.withLock { readsFail = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { writesFail } }
        set { lock.withLock { writesFail = newValue } }
    }

    func load(key: String) throws -> Data? {
        try lock.withLock {
            if readsFail { throw Failure.read }
            return values[key]
        }
    }

    func save(_ data: Data, forKey key: String) throws {
        try lock.withLock {
            if writesFail { throw Failure.write }
            values[key] = data
        }
    }

    func delete(key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

actor TestSecretStore: SecretStoring {
    enum Failure: Error { case mutation }
    private var values: [String: String] = [:]
    private var mutationsFail = false
    private var loadsFail = false
    private(set) var loadCount = 0

    func failMutations(_ failed: Bool) { mutationsFail = failed }
    func failLoads(_ failed: Bool) { loadsFail = failed }

    func load(key: String) async throws -> String? {
        loadCount += 1
        if loadsFail { throw Failure.mutation }
        return values[key]
    }

    func save(_ value: String, forKey key: String) async throws {
        if mutationsFail { throw Failure.mutation }
        values[key] = value
    }

    func delete(key: String) async throws {
        if mutationsFail { throw Failure.mutation }
        values.removeValue(forKey: key)
    }
}
