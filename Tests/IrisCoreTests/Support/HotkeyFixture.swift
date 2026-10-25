import Foundation

@testable import IrisCore

/// An open feed lets tests place edges at actual startup/finalization barriers.
final class TestHotkeyFeed: HotkeyMonitoring, Sendable {
    private let channel = AsyncStream.makeStream(of: HotkeyEvent.self)
    func events() -> AsyncStream<HotkeyEvent> { channel.stream }
    func emit(_ event: HotkeyEvent) { channel.continuation.yield(event) }
    func finish() { channel.continuation.finish() }
}

extension DictationOrchestrator {
    /// A recording state can be forwarded just before the startup task returns.
    /// Join that task too, so the next scripted edge represents a recorded take.
    fileprivate func recordingAfterStartup() async -> Bool {
        _ = await currentTake?.startup?.value
        return isRecording
    }
}

func waitForRecording(_ loop: DictationOrchestrator) async throws {
    let states = await loop.states()
    try await AsyncDeadline.run(seconds: 5) {
        for await state in states {
            switch state {
            case .recording, .partial:
                if await loop.recordingAfterStartup() { return }
            case .error(let message):
                throw TranscriptionError(kind: .invalidState, message: message)
            default: break
            }
        }
        throw TranscriptionError(kind: .invalidState, message: "Recording observation ended unexpectedly.")
    }
}

/// Ordinary successful scripts wait for startup before their later edges.
/// Startup-cancellation tests instead use TestHotkeyFeed and a parked client.
func runRecordingHotkeyScript(_ events: [HotkeyEvent], on loop: DictationOrchestrator) async throws {
    let feed = TestHotkeyFeed()
    let running = Task { await loop.run(hotkey: feed) }
    defer {
        feed.finish()
        running.cancel()
    }
    guard let first = events.first else { return }
    feed.emit(first)
    try await waitForRecording(loop)
    for event in events.dropFirst() { feed.emit(event) }
    feed.finish()
    try await AsyncDeadline.run(seconds: 5) { await running.value }
}
