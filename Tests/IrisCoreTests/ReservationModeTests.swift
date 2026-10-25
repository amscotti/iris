import IrisProviders
import Testing

@testable import IrisCore

@Test(arguments: [HotkeyConfiguration.Mode.hold, .toggle])
func hotkeyIntentUsesTheReservedConfigurationRatherThanThePreflightMode(mode: HotkeyConfiguration.Mode) async throws {
    let reads = TestValue(0)
    let end = ManualGate()
    let watchdog = end.watchdog()
    let inserter = RecordingInserter()
    let config = ProviderConfiguration(provider: .mock)
    let loop = DictationOrchestrator(
        audio: LoopAudio(), inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) }, config: config,
        pressEnder: { await end.wait() },
        configurationSource: {
            let read = reads.update {
                $0 += 1
                return $0
            }
            let preflight: HotkeyConfiguration.Mode = mode == .hold ? .toggle : .hold
            let settings = AppSettings(hotkey: HotkeyConfiguration(mode: read == 1 ? preflight : mode))
            return DictationOrchestrator.Configuration(settings: settings, config: config)
        })
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        watchdog.cancel()
        end.release()
        feed.finish()
        running.cancel()
    }
    feed.emit(.pressed)
    try await waitForRecording(loop)
    #expect(reads.get() == 2)
    #expect(await loop.currentTake?.settings.hotkey.mode == mode)
    feed.emit(.released)
    if mode == .toggle {
        feed.emit(.pressed)
        feed.emit(.released)
    }
    // Keep EOF open: EOF itself finalizes a take and would mask a broken stop edge.
    try await AsyncDeadline.run(seconds: 1) { await end.waitUntilEntered() }
    #expect(await loop.currentTake?.phase == .finalizing)
    end.release()
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
    #expect(inserter.inserts == ["hello world "])
}
