import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

/// Regression coverage for the press lifecycle: every press must be a
/// complete idle -> recording -> finalizing -> idle cycle as seen by a
/// single long-lived observer (the wiring the pill uses), and every final
/// must insert exactly once.
final class PressStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PushToTalkState] = []

    func append(_ state: PushToTalkState) {
        lock.lock()
        stored.append(state)
        lock.unlock()
    }

    var snapshot: [PushToTalkState] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func pressConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

private func pollPress(
    _ description: String, timeoutSeconds: Double = 5,
    _ check: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while await !check() {
        if Date() > deadline {
            return false
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

private func mockLoop(inserter: RecordingInserter) -> DictationOrchestrator {
    DictationOrchestrator(
        audio: StillAudio(),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        settings: .defaults,
        config: pressConfig())
}

@Test func twoConsecutiveUtterancesEachEmitFinalThenIdleAndInsert() async {
    let inserter = RecordingInserter()
    let loop = mockLoop(inserter: inserter)
    let stream = await loop.states()
    let collector = Task {
        var seen: [PushToTalkState] = []
        for await state in stream {
            seen.append(state)
            // Snapshot idle plus six states per press.
            if seen.count >= 13 { break }
        }
        return seen
    }
    await loop.pressBegan()
    await loop.pressEnded()
    await loop.pressBegan()
    await loop.pressEnded()
    let seen = await collector.value
    // Snapshot idle plus six states per press: the fresh service's snapshot
    // idle, recording, two partials, final, idle.
    let cycle: [PushToTalkState] = [
        .idle, .recording(level: 0), .partial("hello"), .partial("hello world"),
        .final("hello world"), .idle,
    ]
    #expect(seen == [.idle] + cycle + cycle)
    #expect(inserter.inserts == ["hello world ", "hello world "])
    #expect(await loop.isPressActive == false)
}

@Test func pressEndDeliversTheWholeBufferedTail() async {
    let partials = (0..<600).map { TranscriptionEvent.partial("word \($0)") }
    let loop = DictationOrchestrator(
        audio: StillAudio(),
        inserter: RecordingInserter(),
        makeService: { _ in TranscriptionService(client: ScriptedClient(events: partials + [.final("done")])) },
        settings: .defaults,
        config: pressConfig())
    let box = PressStateBox()
    let stream = await loop.states()
    // Detached on purpose: when terminal states never arrive, a structured
    // collector would park forever. The box lets the test poll with a bound
    // instead, and the task ends when the loop deallocates.
    Task.detached {
        for await state in stream {
            box.append(state)
        }
    }
    await loop.pressBegan()
    await loop.pressEnded()
    let settled = await pollPress("loop settles back to idle") { await loop.currentState == .idle }
    #expect(settled)
    let deliveredFinal = await pollPress("subscriber sees the final") {
        box.snapshot.contains(.final("done"))
    }
    #expect(deliveredFinal)
    let tailIdle = await pollPress("subscriber sees the trailing idle") { box.snapshot.last == .idle }
    #expect(tailIdle)
}
