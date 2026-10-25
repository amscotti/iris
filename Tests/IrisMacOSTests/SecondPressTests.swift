import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

/// Audio double wired like the production capturer: one stream generation
/// per press. `start()` opens a fresh generation (the tap's new
/// subscription) and `stop()` ends it (suspended stage tasks terminate), so
/// consecutive presses each receive the frames yielded while held.
final class GenerationalAudio: AudioCapturing, @unchecked Sendable {
    private let host = RestartableStream<PCMFrame>()

    func frames() -> AsyncStream<PCMFrame> { host.currentStream }

    func start() { host.rotate() }

    func stop() { host.finish() }

    func emit(_ frame: PCMFrame) { host.currentContinuation.yield(frame) }
}

final class PressClientCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MockTranscriptionClient] = []

    func add(_ client: MockTranscriptionClient) {
        lock.lock()
        stored.append(client)
        lock.unlock()
    }

    var all: [MockTranscriptionClient] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class PressInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func insert(_ text: String) {
        lock.lock()
        stored.append(text)
        lock.unlock()
    }

    var inserts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func secondPressConfig() -> ProviderConfiguration {
    ProviderConfiguration(provider: .mock, values: ["apiKey": "k"])
}

private func secondPressFrame() -> PCMFrame {
    PCMFrame(samples: [Int16](repeating: 2000, count: 1600))
}

private func pollSecondPress(_ check: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !check() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

private func driveSecondPress(
    loop: DictationOrchestrator, audio: GenerationalAudio, clients: PressClientCollector, frameCount: Int
) async -> Bool {
    await loop.pressBegan()
    for _ in 0..<frameCount { audio.emit(secondPressFrame()) }
    let delivered = await pollSecondPress {
        (clients.all.last?.receivedFrameCount ?? 0) >= frameCount
    }
    await loop.pressEnded()
    return delivered
}

@Test func secondPressReceivesFramesAndInserts() async {
    let audio = GenerationalAudio()
    let inserter = PressInserter()
    let clients = PressClientCollector()
    let loop = DictationOrchestrator(
        audio: audio,
        inserter: inserter,
        makeService: { _ in
            let client = MockTranscriptionClient()
            clients.add(client)
            return TranscriptionService(client: client)
        },
        settings: .defaults,
        config: secondPressConfig(),
        pressStarter: {
            audio.start()
            return nil
        },
        pressEnder: { audio.stop() })

    #expect(await driveSecondPress(loop: loop, audio: audio, clients: clients, frameCount: 2))
    #expect(await driveSecondPress(loop: loop, audio: audio, clients: clients, frameCount: 10))

    let seen = clients.all
    #expect(seen.count == 2)
    #expect(seen[0].receivedFrameCount >= 2)
    // The second press's fresh service must see its own audio. Before the
    // capture lifecycle ended each generation, this count stayed zero: the
    // first press's cancelled pump kept absorbing every frame.
    #expect(seen[1].receivedFrameCount >= 10)
    #expect(inserter.inserts == ["hello world ", "hello world "])
    #expect(await loop.isPressActive == false)
}

@Test func releaseDrainsAudioIncludingTheCapturersFinalFrame() async {
    let audio = GenerationalAudio()
    let client = MockTranscriptionClient()
    let loop = DictationOrchestrator(
        audio: audio,
        makeService: { _ in TranscriptionService(client: client) },
        config: secondPressConfig(),
        pressStarter: {
            audio.start()
            return nil
        },
        pressEnder: {
            audio.emit(secondPressFrame())
            audio.stop()
        })
    await loop.pressBegan()
    for _ in 0..<50 { audio.emit(secondPressFrame()) }
    // No wait for the pump: release races a backlog exactly as a short take
    // or slow connection can. Every frame must precede the end marker.
    await loop.pressEnded()
    #expect(client.receivedFrameCount == 51)
    #expect(client.finishCallCount == 1)
}

@Test func changingProviderMidTakeKeepsTheCapturedRouteAndRewrite() async {
    let prompt = PromptDefinition(name: "Rewrite")
    let settings = AppSettings(prompts: [prompt], selectedPromptID: prompt.id)
    let box = PressConfigurationBox(
        settings: settings,
        config: ProviderConfiguration(
            provider: .meta, values: ["apiKey": "meta-key", "rewriteModel": "muse-first", "rewriteEffort": "minimal"]))
    let inserter = PressInserter()
    let audio = GenerationalAudio()
    let loop = DictationOrchestrator(
        audio: audio, inserter: inserter,
        makeService: { _ in TranscriptionService(client: MockTranscriptionClient()) },
        config: ProviderConfiguration(provider: .mock),
        pressStarter: {
            audio.start()
            return nil
        },
        pressEnder: { audio.stop() },
        configurationSource: {
            let snapshot = box.current()
            return .init(settings: snapshot.settings, config: snapshot.config)
        },
        rewriteFactory: { config in
            let rewrite = RewriteConfiguration(config: config, registry: AppProviderAssembly.defaultRegistry())
            return { _, _ in
                "\(config.provider.name):\(config.apiKey ?? "missing"):\(rewrite?.model ?? "missing"):\(rewrite?.effort.rawValue ?? "missing")"
            }
        })
    await loop.pressBegan()
    var updated = settings
    updated.providerName = "Grok"
    updated.trailingSpace = false
    box.update(
        settings: updated,
        config: ProviderConfiguration(
            provider: .grok, values: ["apiKey": "grok-key", "rewriteModel": "grok-second", "rewriteEffort": "high"]))
    await loop.pressEnded()
    await loop.pressBegan()
    await loop.pressEnded()
    #expect(inserter.inserts == ["Meta:meta-key:muse-first:minimal ", "Grok:grok-key:grok-second:high"])
}
