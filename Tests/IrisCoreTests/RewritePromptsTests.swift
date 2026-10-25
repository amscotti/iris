import Foundation
import Testing

@testable import IrisCore
@testable import IrisProviders

// MARK: - Single selection

/// Runner double that records calls and applies scripted behavior.
final class ScriptedRunner: Sendable {
    private let log = RunnerLog()
    let behavior: @Sendable (String, PromptDefinition) -> String?

    init(behavior: @escaping @Sendable (String, PromptDefinition) -> String?) {
        self.behavior = behavior
    }

    func run(_ text: String, _ prompt: PromptDefinition) async -> String? {
        await log.record(text: text, name: prompt.name)
        return behavior(text, prompt)
    }

    var callCount: Int {
        get async { await log.calls.count }
    }

    var seenNames: [String] {
        get async { await log.calls.map { $0.1 } }
    }
}

actor RunnerLog {
    var calls: [(String, String)] = []

    func record(text: String, name: String) {
        calls.append((text, name))
    }
}

private func prompt(
    name: String, order: Int, template: String = "{{transcript}}"
) -> PromptDefinition {
    PromptDefinition(name: name, template: template, order: order)
}

private func selecting(_ prompts: [PromptDefinition], id: UUID?) -> AppSettings {
    var settings = AppSettings.defaults
    settings.prompts = prompts
    settings.selectedPromptID = id
    return settings
}

@Test func singleApplyRunsOnlyTheSelectedPrompt() async {
    let first = prompt(name: "first", order: 0)
    let second = prompt(name: "second", order: 1)
    let runner = ScriptedRunner { text, step in "\(text)[\(step.name)]" }
    let outcome = await RewritePrompt.run(
        text: "go", settings: selecting([first, second], id: second.id), runner: runner.run)
    #expect(outcome == RewritePrompt.Outcome(text: "go[second]", failed: false))
    #expect(await runner.seenNames == ["second"])
}

@Test func noneSelectedNeverInvokesRunner() async {
    let prompts = [prompt(name: "a", order: 0), prompt(name: "b", order: 1)]
    let runner = ScriptedRunner { text, _ in "\(text)!" }
    let outcome = await RewritePrompt.run(
        text: "go", settings: selecting(prompts, id: nil), runner: runner.run)
    #expect(outcome == RewritePrompt.Outcome(text: "go", failed: false))
    #expect(await runner.callCount == 0)
}

@Test func unknownSelectedIDBehavesAsNone() async {
    let prompts = [prompt(name: "a", order: 0)]
    let runner = ScriptedRunner { text, _ in "\(text)!" }
    let outcome = await RewritePrompt.run(
        text: "go", settings: selecting(prompts, id: UUID()), runner: runner.run)
    #expect(outcome == RewritePrompt.Outcome(text: "go", failed: false))
    #expect(await runner.callCount == 0)
}

@Test func singleApplyFailureKeepsTextAsItStood() async {
    let only = prompt(name: "bad", order: 0)
    let runner = ScriptedRunner { _, _ in nil }
    let outcome = await RewritePrompt.run(
        text: "go", settings: selecting([only], id: only.id), runner: runner.run)
    #expect(outcome == RewritePrompt.Outcome(text: "go", failed: true))
    #expect(await runner.seenNames == ["bad"])
}

@Test func blankRewriteKeepsOriginalText() async {
    let only = prompt(name: "empty", order: 0)
    let runner = ScriptedRunner { _, _ in "   " }
    let outcome = await RewritePrompt.run(
        text: "go", settings: selecting([only], id: only.id), runner: runner.run)
    #expect(outcome == RewritePrompt.Outcome(text: "go", failed: true))
}

@Test func selectionResolvesNilWithoutASStoredMatch() {
    var settings = AppSettings.defaults
    let only = prompt(name: "a", order: 0)
    settings.prompts = [only]
    #expect(settings.selectedPrompt == nil)
    settings.selectedPromptID = UUID()
    #expect(settings.selectedPrompt == nil)
    settings.selectedPromptID = only.id
    #expect(settings.selectedPrompt == only)
}

// MARK: - Persistence

@Test func promptsSurvivePersistenceRoundTrip() throws {
    let persistence = MemoryPersistence()
    var settings = AppSettings.defaults
    settings.prompts = [
        PromptDefinition(name: "Cleanup", template: "Fix {{transcript}}", order: 0),
        PromptDefinition(name: "Formal", template: "Formalize", order: 1),
    ]
    settings.selectedPromptID = settings.prompts[0].id
    try settings.save(to: persistence)
    let loaded = try AppSettings.load(from: persistence)
    #expect(loaded == settings)
    #expect(loaded.prompts.count == 2)
    #expect(loaded.prompts[1].template == "Formalize")
    #expect(loaded.selectedPrompt == loaded.prompts[0])
}

@Test func payloadWithoutPromptsLoadsEmpty() throws {
    let legacy = """
        {"providerName":"Meta","providerValues":{},"hotkey":{"keyCode":61,"modifiers":0,"mode":"hold"},\
        "insertMethod":"keystroke","trailingSpace":true,"trailingNewline":false,"reduceMotion":false}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(loaded.prompts.isEmpty)
    #expect(loaded.selectedPromptID == nil)
}

// MARK: - Toggle migration

private func legacyPayload(prompts: String, selection: String = "") throws -> AppSettings {
    let json = """
        {"providerName":"Meta","providerValues":{},"hotkey":{"keyCode":61,"modifiers":0,"mode":"hold"},\
        "insertMethod":"keystroke","trailingSpace":true,"trailingNewline":false,"reduceMotion":false,\
        "prompts":[\(prompts)]\(selection)}
        """
    return try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

private func legacyPrompt(id: String, order: Int, enabled: Bool) -> String {
    """
    {"id":"\(id)","name":"p\(order)","template":"{{transcript}}",\
    "model":"muse-spark-1.3","effort":"minimal","enabled":\(enabled ? "true" : "false"),"order":\(order)}
    """
}

@Test func migrationKeepsFirstOfManyEnabled() throws {
    let loaded = try legacyPayload(
        prompts: [
            legacyPrompt(id: "11111111-1111-1111-1111-111111111111", order: 0, enabled: true),
            legacyPrompt(id: "22222222-2222-2222-2222-222222222222", order: 1, enabled: true),
        ].joined(separator: ","))
    #expect(loaded.prompts.count == 2)
    #expect(loaded.selectedPromptID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    #expect(loaded.selectedPrompt?.order == 0)
}

@Test func migrationKeepsSingleEnabled() throws {
    let loaded = try legacyPayload(
        prompts: [
            legacyPrompt(id: "11111111-1111-1111-1111-111111111111", order: 0, enabled: false),
            legacyPrompt(id: "22222222-2222-2222-2222-222222222222", order: 1, enabled: true),
        ].joined(separator: ","))
    #expect(loaded.selectedPromptID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
}

@Test func migrationWithNoneEnabledSelectsNone() throws {
    let loaded = try legacyPayload(
        prompts: [
            legacyPrompt(id: "11111111-1111-1111-1111-111111111111", order: 0, enabled: false)
        ].joined(separator: ","))
    #expect(loaded.selectedPromptID == nil)
    #expect(loaded.selectedPrompt == nil)
}

@Test func unknownSelectedIDLoadsAsNone() throws {
    let loaded = try legacyPayload(
        prompts: [
            legacyPrompt(id: "11111111-1111-1111-1111-111111111111", order: 0, enabled: false)
        ].joined(separator: ","),
        selection: #","selectedPromptID":"33333333-3333-3333-3333-333333333333""#)
    #expect(loaded.selectedPromptID == nil)
    #expect(loaded.selectedPrompt == nil)
}

@Test func savedSelectionWinsOverLegacyToggles() throws {
    let loaded = try legacyPayload(
        prompts: [
            legacyPrompt(id: "11111111-1111-1111-1111-111111111111", order: 0, enabled: true),
            legacyPrompt(id: "22222222-2222-2222-2222-222222222222", order: 1, enabled: true),
        ].joined(separator: ","),
        selection: #","selectedPromptID":"22222222-2222-2222-2222-222222222222""#)
    #expect(loaded.selectedPromptID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
}

@Test func rewriteModelFallsBackToItsProviderDefaultWhenUnset() {
    let meta = RewriteConfiguration(
        config: ProviderConfiguration(provider: .meta, values: ["rewriteModel": ""]), registry: testProviderRegistry())
    let grok = RewriteConfiguration(
        config: ProviderConfiguration(provider: .grok, values: ["rewriteModel": " \n"]),
        registry: testProviderRegistry())
    #expect(meta?.model == "muse-spark-1.3")
    #expect(meta?.effort == .minimal)
    #expect(grok?.model == "grok-4.6")
    #expect(grok?.effort == .low)
}

@Test func storedPromptMissingFieldsUseDefaults() throws {
    let json = """
        {"providerName":"Meta","providerValues":{},"hotkey":{"keyCode":61,"modifiers":0,"mode":"hold"},\
        "insertMethod":"keystroke","trailingSpace":true,"trailingNewline":false,"reduceMotion":false,\
        "prompts":[{"id":"11111111-1111-1111-1111-111111111111","name":"Bare"}]}
        """
    let loaded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    let prompt = try #require(loaded.prompts.first)
    #expect(prompt.name == "Bare")
    #expect(prompt.template == "")
    #expect(prompt.order == 0)
}

@Test func encodedPromptsDoNotWriteLegacyEnabledToggle() throws {
    var settings = AppSettings.defaults
    settings.prompts = [PromptDefinition(name: "Cleanup", template: "{{transcript}}", order: 0)]
    settings.selectedPromptID = settings.prompts[0].id
    let text = String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? ""
    #expect(!text.contains("\"enabled\""))
    #expect(text.contains("selectedPromptID"))
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    let prompts = try #require(object["prompts"] as? [[String: Any]])
    #expect(prompts[0]["model"] == nil)
    #expect(prompts[0]["effort"] == nil)
}

// MARK: - Orchestrator pipeline

/// Locked recorder for states observed during a press.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PushToTalkState] = []

    func record(_ state: PushToTalkState) {
        lock.lock()
        stored.append(state)
        lock.unlock()
    }

    var states: [PushToTalkState] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func waitForRewrite(_ description: String, until condition: @escaping @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting: \(description)")
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private struct RewriteLoop {
    var loop: DictationOrchestrator
    var inserter: RecordingInserter
}

private func rewriteLoop(settings: AppSettings, runner: PromptRewrite?) -> RewriteLoop {
    let client = MockTranscriptionClient()
    let inserter = RecordingInserter()
    let loop = DictationOrchestrator(
        audio: LoopAudio(frames: [PCMFrame(samples: [1000, -1000, 1000, -1000])]),
        inserter: inserter,
        makeService: { _ in TranscriptionService(client: client) },
        settings: settings,
        config: ProviderConfiguration(provider: .mock, values: ["apiKey": "k"]),
        rewriteRunner: runner)
    return RewriteLoop(loop: loop, inserter: inserter)
}

/// Subscribes before returning, so no state emitted after this call is
/// missed however late the recording task starts.
private func observe(_ loop: DictationOrchestrator, into recorder: StateRecorder) async -> Task<Void, Never> {
    let stream = await loop.states()
    return Task {
        for await state in stream {
            recorder.record(state)
        }
    }
}

@Test func orchestratorAppliesOnlyTheSelectedPrompt() async {
    let first = prompt(name: "a", order: 0)
    let second = prompt(name: "b", order: 1)
    let runner = ScriptedRunner { text, step in "\(text)[\(step.name)]" }
    let fixture = rewriteLoop(settings: selecting([first, second], id: second.id), runner: runner.run)
    let recorder = StateRecorder()
    let observation = await observe(fixture.loop, into: recorder)
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    await waitForRewrite("enhanced insert") { fixture.inserter.inserts.count == 1 }
    #expect(fixture.inserter.inserts == ["hello world[b] "])
    #expect(await runner.seenNames == ["b"])
    await waitForRewrite("rewritten final state") { recorder.states.contains(.final("hello world[b]")) }
    #expect(recorder.states.contains(.enhancing))
    #expect(recorder.states.contains(.final("hello world[b]")))
    observation.cancel()
}

@Test func orchestratorBypassWithNoneAddsNoStates() async {
    // Prompts present but None selected: the exact zero-LLM bypass.
    // Output is identical to the raw transcript, the runner never fires,
    // and no enhancement or error states appear.
    let settings = selecting([prompt(name: "a", order: 0), prompt(name: "b", order: 1)], id: nil)
    #expect(settings.selectedPrompt == nil)
    let runner = ScriptedRunner { text, _ in "\(text)!" }
    let fixture = rewriteLoop(settings: settings, runner: runner.run)
    let recorder = StateRecorder()
    let observation = await observe(fixture.loop, into: recorder)
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    await waitForRewrite("raw insert") { fixture.inserter.inserts.count == 1 }
    #expect(fixture.inserter.inserts == ["hello world "])
    #expect(await runner.callCount == 0)
    #expect(!recorder.states.contains(.enhancing))
    #expect(
        !recorder.states.contains(where: {
            if case .error = $0 { return true }
            return false
        }))
    observation.cancel()
}

@Test func orchestratorUsesUpdatedSelectionOnNextPress() async {
    let chosen = prompt(name: "tidy", order: 0)
    let runner = ScriptedRunner { text, step in "\(text)[\(step.name)]" }
    let fixture = rewriteLoop(settings: selecting([chosen], id: nil), runner: runner.run)
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    await waitForRewrite("raw first press") { fixture.inserter.inserts.count == 1 }
    #expect(fixture.inserter.inserts == ["hello world "])
    #expect(await runner.callCount == 0)
    await fixture.loop.update(
        settings: selecting([chosen], id: chosen.id),
        config: ProviderConfiguration(provider: .mock, values: ["apiKey": "k"]))
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    await waitForRewrite("rewritten second press") { fixture.inserter.inserts.count == 2 }
    #expect(fixture.inserter.inserts == ["hello world ", "hello world[tidy] "])
    #expect(await runner.seenNames == ["tidy"])
}

@Test func orchestratorFailureTypesRawTextWithBriefError() async {
    let bad = prompt(name: "bad", order: 0)
    let settings = selecting([bad], id: bad.id)
    let runner = ScriptedRunner { _, _ in nil }
    let fixture = rewriteLoop(settings: settings, runner: runner.run)
    let recorder = StateRecorder()
    let observation = await observe(fixture.loop, into: recorder)
    await fixture.loop.pressBegan()
    await fixture.loop.pressEnded()
    await waitForRewrite("fallback insert") { fixture.inserter.inserts.count == 1 }
    #expect(fixture.inserter.inserts == ["hello world "])
    await waitForRewrite("error state") {
        let states = recorder.states
        return states.contains(.error("Rewrite failed. Inserted the original text.")) && states.last == .idle
    }
    #expect(recorder.states.last == .idle)
    observation.cancel()
}
