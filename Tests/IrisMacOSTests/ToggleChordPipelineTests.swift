import AppKit
import Foundation
import IrisProviders
import Testing

@testable import IrisCore
@testable import IrisMacOS

private final class ToggleChordClient: TranscriptionClient, Sendable {
    let delivered = AsyncStream.makeStream(of: Void.self)
    let ending = AsyncStream.makeStream(of: Void.self)
    let channel = AsyncThrowingStream.makeStream(of: TranscriptionEvent.self, throwing: Error.self)
    func start(config: ProviderConfiguration) async throws {}
    func sendAudio(_ frame: PCMFrame) async throws { delivered.continuation.yield(()) }
    func events() -> AsyncThrowingStream<TranscriptionEvent, Error> { channel.stream }
    func endAudio() async throws {
        ending.continuation.yield(())
        channel.continuation.yield(.final("spoken words"))
        channel.continuation.finish()
    }
    func cancel() async { channel.continuation.finish(throwing: CancellationError()) }
}

private func waitForCapturedFrame(audio: RuntimeTestAudio, client: ToggleChordClient) async throws {
    try await AsyncDeadline.run(seconds: 5) {
        var started = audio.started.stream.makeAsyncIterator()
        _ = await started.next()
        await audio.emitFrame()
        var delivered = client.delivered.stream.makeAsyncIterator()
        _ = await delivered.next()
    }
}

@MainActor
private func emitTypingChord(_ backend: TestHotkeyEvents, option: UInt) {
    // Real physics: Right Option is physically down while the chord types.
    backend.keyPressed = true
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61, modifiers: option))
    backend.globalHandlers.first?(.init(kind: .keyDown, keyCode: 0, modifiers: option))
    backend.globalHandlers.first?(.init(kind: .keyUp, keyCode: 0, modifiers: option))
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61))
    backend.keyPressed = false
}

@Test @MainActor func classifiedOptionTypingChordKeepsTheEstablishedToggleTake() async throws {
    let backend = TestHotkeyEvents()
    let monitor = GlobalHotkeyMonitor(backend: backend)
    #expect(monitor.start())
    let audio = RuntimeTestAudio()
    let inserter = RuntimeTestInserter()
    let client = ToggleChordClient()
    var settings = AppSettings.defaults
    settings.hotkey.mode = .toggle
    let loop = DictationOrchestrator(
        audio: audio, inserter: inserter, makeService: { _ in TranscriptionService(client: client) },
        settings: settings, config: ProviderConfiguration(provider: .mock),
        pressStarter: {
            try? await audio.start()
            return nil
        }, pressEnder: { await audio.stop() })
    let running = Task { await loop.run(hotkey: monitor) }
    defer {
        running.cancel()
        monitor.stop()
    }
    let option = NSEvent.ModifierFlags.option.rawValue
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61, modifiers: option))
    try await waitForCapturedFrame(audio: audio, client: client)
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61))
    let states = await loop.states()
    client.channel.continuation.yield(.partial("spoken words"))
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states where state == .partial("spoken words") { return }
    }
    // The classifier emits pressed, cancelled, then silences this chord's up.
    emitTypingChord(backend, option: option)
    let prematureEnd = await AsyncDeadline.shutdown(seconds: 0.05) {
        var ending = client.ending.stream.makeAsyncIterator()
        _ = await ending.next()
    }
    #expect(prematureEnd == .timedOut)
    #expect(await audio.stops == 0)
    #expect(inserter.targets.isEmpty)
    #expect(await loop.isPressActive)
    // A fresh, unchorded tap still stops and inserts, before stream EOF.
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61, modifiers: option))
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61))
    let inserted = try await AsyncDeadline.run(seconds: 5) {
        var insertion = inserter.inserted.stream.makeAsyncIterator()
        return await insertion.next()
    }
    #expect(inserted == "spoken words ")
    #expect(await audio.stops == 1)
    monitor.stop()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
}
