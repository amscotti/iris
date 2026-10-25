import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func userCancellationEmitsTypedNoticeWithoutStoppingInputRuntime() async throws {
    let fixture = RuntimeFixture()
    let store = TestEnvironment()
    try await store.secrets.save("fixture-key", forKey: "iris.apikey.Meta")
    let environment = store.make(
        permissions: PermissionsManager(microphoneStatus: .granted, accessibilityGranted: true),
        runtimePorts: fixture.ports())
    await environment.start()
    do {
        try await fixture.beginRecordedTake(in: environment)
        let notices = AsyncStream.makeStream(of: DictationNotice.self)
        let original = environment.runtime.onNotice
        environment.runtime.onNotice = { notice in
            original?(notice)
            notices.continuation.yield(notice)
        }

        #expect(await environment.runtime.cancelDictation())
        let notice = try await AsyncDeadline.run(seconds: 5) {
            var stream = notices.stream.makeAsyncIterator()
            return await stream.next()
        }
        #expect(notice == .cancelled(.userRequested))
        #expect(environment.runtime.isStarted)
        #expect(environment.runtime.isMonitoring)
        #expect(await environment.runtime.cancelDictation() == false)
        #expect(fixture.inserter.targets.isEmpty)
    } catch {
        await environment.stop()
        throw error
    }
    await environment.stop()
}
