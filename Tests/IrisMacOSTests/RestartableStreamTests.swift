import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

/// Sendable flag box for observing stream termination across tasks.
final class GenerationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Sendable frame sink for collecting one generation's deliveries.
final class GenerationSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PCMFrame] = []

    func append(_ frame: PCMFrame) {
        lock.lock()
        stored.append(frame)
        lock.unlock()
    }

    var snapshot: [PCMFrame] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func generationFrame(_ sample: Int16 = 1000) -> PCMFrame {
    PCMFrame(samples: [Int16](repeating: sample, count: 160))
}

private func settleGenerations(nanoseconds: UInt64 = 20_000_000) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
}

private func pollGeneration(_ check: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !check() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

@Test func freshGenerationDeliversToItsSubscriber() async {
    let host = RestartableStream<PCMFrame>()
    let sink = GenerationSink()
    Task.detached { [stream = host.currentStream] in
        for await frame in stream {
            sink.append(frame)
            if sink.snapshot.count >= 2 { break }
        }
    }
    await settleGenerations()
    host.currentContinuation.yield(generationFrame())
    host.currentContinuation.yield(generationFrame())
    #expect(await pollGeneration { sink.snapshot.count >= 2 })
}

@Test func rotateEndsThePreviousGeneration() async {
    let host = RestartableStream<PCMFrame>()
    let ended = GenerationFlag()
    Task.detached { [stream = host.currentStream] in
        for await _ in stream {}
        ended.set()
    }
    await settleGenerations()
    host.rotate()
    #expect(await pollGeneration { ended.value })
}

@Test func cancelledSubscriberDoesNotStarveTheNextGeneration() async {
    let host = RestartableStream<PCMFrame>()
    let firstEnded = GenerationFlag()
    // The previous press's consumer: cancelled while suspended, exactly how a
    // per-press pump is torn down at press end.
    let first = Task.detached { [stream = host.currentStream] in
        for await _ in stream {}
        firstEnded.set()
    }
    await settleGenerations()
    first.cancel()
    await settleGenerations()
    host.rotate()
    #expect(await pollGeneration { firstEnded.value })

    let sink = GenerationSink()
    Task.detached { [stream = host.currentStream] in
        for await frame in stream {
            sink.append(frame)
            if sink.snapshot.count >= 3 { break }
        }
    }
    await settleGenerations()
    host.currentContinuation.yield(generationFrame(1))
    host.currentContinuation.yield(generationFrame(2))
    host.currentContinuation.yield(generationFrame(3))
    #expect(await pollGeneration { sink.snapshot.count >= 3 })
    #expect(sink.snapshot.map { $0.samples.first ?? 0 } == [1, 2, 3])
}

@Test func finishEndsTheStreamAndDropsLaterYields() async {
    let host = RestartableStream<PCMFrame>()
    let ended = GenerationFlag()
    let sink = GenerationSink()
    Task.detached { [stream = host.currentStream] in
        for await frame in stream {
            sink.append(frame)
        }
        ended.set()
    }
    await settleGenerations()
    host.currentContinuation.yield(generationFrame())
    host.finish()
    host.finish()
    host.currentContinuation.yield(generationFrame())
    #expect(await pollGeneration { ended.value })
    #expect(sink.snapshot.count == 1)
}
