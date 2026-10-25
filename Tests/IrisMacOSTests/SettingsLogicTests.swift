import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS
@testable import IrisProviders

@Test @MainActor func hotkeyOptionsListModifierKeysWithDefault() {
    #expect(ShortcutTab.keyOptions.count == 8)
    #expect(ShortcutTab.keyOptions.contains(where: { $0.name == "Right Option" && $0.keyCode == 61 }))
    #expect(ShortcutTab.keyOptions.contains(where: { $0.keyCode == HotkeyConfiguration().keyCode }))
}

@Test @MainActor func hotkeyConflictWarningFlagsCrowdedKeys() {
    #expect(ShortcutTab.conflictWarning(for: 54) != nil)
    #expect(ShortcutTab.conflictWarning(for: 55) != nil)
    #expect(ShortcutTab.conflictWarning(for: 56) != nil)
    #expect(ShortcutTab.conflictWarning(for: 60) != nil)
    #expect(ShortcutTab.conflictWarning(for: 61)?.contains("held on its own") == true)
    #expect(ShortcutTab.conflictWarning(for: 58)?.contains("held on its own") == true)
    #expect(ShortcutTab.conflictWarning(for: 0) == nil)
}

@Test @MainActor func advancedDisplayNamesStayPlainWords() {
    let meta = MetaProvider().descriptor
    let grok = GrokProvider().descriptor
    #expect(meta.field(for: "audioEncoding")?.displayName(for: "PCM_16KHZ") == "Standard (16 kHz)")
    #expect(meta.field(for: "audioEncoding")?.displayName(for: "PCM_24KHZ") == "Higher (24 kHz)")
    #expect(meta.field(for: "mode")?.displayName(for: "PUSH_TO_TALK") == "Push to talk")
    #expect(meta.field(for: "mode")?.displayName(for: "ENDPOINTING") == "Endpointing")
    #expect(meta.field(for: "mode")?.displayName(for: "DIARIZATION") == "Diarization")
    #expect(meta.field(for: "mode")?.displayName(for: "FUTURE") == "FUTURE")
    #expect(grok.field(for: "languageBias")?.displayName(for: "en") == "English")
    #expect(MetaProvider().displayValue("en", for: "languageBias") == "English")
}

@Test @MainActor func settingsTabsHaveTitlesInOrder() {
    #expect(
        SettingsTab.allCases == [.providers, .shortcut, .prompts, .typing, .appearance, .permissions])
    #expect(SettingsTab.appearance.title == "Appearance")
    #expect(SettingsTab.providers.title == "Providers")
    #expect(SettingsTab.shortcut.title == "Shortcut")
    #expect(SettingsTab.permissions.title == "Permissions")
    #expect(SettingsTab.prompts.title == "Prompts")
    #expect(SettingsTab.typing.title == "Typing")
}

@Test func settingsTabsKeepTheirPersistedPaneIDs() {
    // Renamed cases must keep restoring panes saved by earlier builds.
    #expect(
        SettingsTab.allCases.map(\.rawValue) == [
            "dictation", "hotkey", "prompts", "advanced", "general", "permissions",
        ])
}

@Test @MainActor func settingsPageHasAFixedSize() {
    #expect(SettingsPage.width == 780)
    #expect(SettingsPage.height == 560)
}

@Test @MainActor func settingsWindowCanGrowBeyondItsDefaultPageSize() {
    let window = SettingsWindowController.makeWindow()
    #expect(window.styleMask.contains(.resizable))
    #expect(window.contentMinSize == NSSize(width: SettingsPage.width, height: SettingsPage.height))
}

@Test func providerActionsExplainWhyTheyAreDisabled() {
    #expect(ProviderPresentation.useHelp(providerName: "Meta", state: .missing) == "Save an API key first")
    #expect(
        ProviderPresentation.useHelp(providerName: "Meta", state: .unavailable("Locked"))
            == "Unlock Keychain before using Meta")
    #expect(
        ProviderPresentation.testConnectionDisabledReason(hasKey: false, showsEditor: false, saving: false)
            == "Save an API key before testing the connection.")
    #expect(
        ProviderPresentation.testConnectionDisabledReason(hasKey: true, showsEditor: true, saving: false)
            == "Save or cancel the API key edit before testing.")
    #expect(
        ProviderPresentation.testConnectionDisabledReason(hasKey: true, showsEditor: false, saving: true)
            == "Wait for the API key to finish saving.")
    #expect(
        ProviderPresentation.testConnectionDisabledReason(hasKey: true, showsEditor: false, saving: false) == nil)
}

@Test func providerConnectionResultsHaveVoiceOverAnnouncements() {
    #expect(
        ProviderPresentation.connectionAnnouncement(providerName: "Meta", state: .connected)
            == "Meta speech connection verified.")
    #expect(
        ProviderPresentation.connectionAnnouncement(providerName: "Meta", state: .failed("No network connection."))
            == "Meta connection failed: No network connection.")
    #expect(ProviderPresentation.connectionAnnouncement(providerName: "Meta", state: .checking) == nil)
    #expect(ProviderPresentation.connectionAnnouncement(providerName: "Meta", state: .notChecked) == nil)
}

// MARK: - Prompt enablement

@Test @MainActor func promptSelectionPersistsAndTakesEffect() {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    let created = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    environment.selectPrompt(id: created.id)
    #expect(environment.selectedPromptID == created.id)
    #expect(environment.selectedPrompt == created)
    environment.selectPrompt(id: nil)
    #expect(environment.selectedPromptID == nil)
    #expect(environment.selectedPrompt == nil)
    let relaunched = fixture.make()
    #expect(relaunched.selectedPromptID == nil)
    #expect(relaunched.selectedPrompt == nil)
    relaunched.selectPrompt(id: created.id)
    #expect(relaunched.selectedPrompt == created)
    let relaunchedAgain = fixture.make()
    #expect(relaunchedAgain.selectedPromptID == created.id)
}

@Test @MainActor func noneSelectionTracksPromptSelectionBothDirections() {
    let fixture = TestEnvironment()
    #expect(AppSettings.defaults.prompts.isEmpty)
    let environment = fixture.make()
    #expect(environment.selectedPromptID == nil)
    let first = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    environment.selectPrompt(id: first.id)
    #expect(environment.selectedPromptID == first.id)
    let second = environment.addExamplePrompt()
    #expect(environment.selectedPromptID == first.id)
    environment.selectPrompt(id: second.id)
    #expect(environment.selectedPromptID == second.id)
    environment.selectPrompt(id: first.id)
    #expect(environment.selectedPromptID == first.id)
    environment.selectPrompt(id: nil)
    #expect(environment.selectedPromptID == nil)
    #expect(environment.settings.prompts.count == 2)
    let relaunched = fixture.make()
    #expect(relaunched.selectedPromptID == nil)
    #expect(relaunched.settings.prompts.count == 2)
}

@Test @MainActor func examplePromptAddedUnselectedNeverStealsSelection() {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    let example = environment.addExamplePrompt()
    #expect(environment.selectedPromptID == nil)
    let active = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    environment.selectPrompt(id: active.id)
    #expect(environment.selectedPromptID == active.id)
    let secondExample = environment.addExamplePrompt()
    #expect(secondExample.id != active.id)
    #expect(environment.selectedPromptID == active.id)
    let relaunched = fixture.make()
    #expect(relaunched.selectedPromptID == active.id)
    #expect(relaunched.prompt(id: example.id) != nil)
}

@Test @MainActor func deletingActivePromptReturnsToNone() {
    let environment = TestEnvironment().make()
    let first = environment.addPrompt()
    let second = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    environment.selectPrompt(id: second.id)
    #expect(environment.selectedPromptID == second.id)
    environment.deletePrompt(id: second.id)
    #expect(environment.selectedPromptID == nil)
    #expect(environment.prompt(id: second.id) == nil)
    environment.selectPrompt(id: first.id)
    environment.deletePrompt(id: first.id)
    #expect(environment.selectedPromptID == nil)
}

@Test @MainActor func unknownPromptSelectionIsIgnored() {
    let environment = TestEnvironment().make()
    environment.selectPrompt(id: UUID())
    #expect(environment.selectedPromptID == nil)
    let created = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    environment.selectPrompt(id: created.id)
    environment.selectPrompt(id: UUID())
    #expect(environment.selectedPromptID == created.id)
}

// MARK: - Prompt editing split from activation

@Test @MainActor func newPromptTemplateIncludesTranscriptPlaceholder() {
    let environment = TestEnvironment().make()
    #expect(PromptDefinition.defaultTemplate.contains(RewritePromptRenderer.placeholder))
    let created = environment.addPrompt()
    #expect(created.template.contains(RewritePromptRenderer.placeholder))
    #expect(environment.prompt(id: created.id)?.template.contains(RewritePromptRenderer.placeholder) == true)
}

@Test @MainActor func addPromptLeavesSelectionUntouched() {
    let environment = TestEnvironment().make()
    #expect(environment.selectedPromptID == nil)
    let first = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    #expect(environment.prompt(id: first.id) != nil)
    environment.selectPrompt(id: first.id)
    #expect(environment.selectedPromptID == first.id)
    let second = environment.addPrompt()
    #expect(environment.selectedPromptID == first.id)
    #expect(environment.prompt(id: second.id) != nil)
    environment.selectPrompt(id: nil)
    let third = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    #expect(environment.prompt(id: third.id) != nil)
}

@Test @MainActor func promptsCreatedWhileGrokIsActiveAreSharedText() {
    let environment = TestEnvironment().make()
    environment.setProvider(ProviderID.grok.name)
    let created = environment.addPrompt()
    let example = environment.addExamplePrompt()
    environment.setProvider(ProviderID.meta.name)
    #expect(environment.prompt(id: created.id) == created)
    #expect(environment.prompt(id: example.id) == example)
}

@Test @MainActor func duplicatePromptCopiesContentWithoutTouchingActivation() {
    let environment = TestEnvironment().make()
    let active = environment.addPrompt()
    #expect(environment.selectedPromptID == nil)
    environment.selectPrompt(id: active.id)
    var edited = active
    edited.name = "Tidy"
    edited.template = "Tidy up:\n\n{{transcript}}"
    environment.updatePrompt(edited)
    let copy = environment.duplicatePrompt(id: active.id)
    #expect(copy != nil)
    #expect(copy?.name == "Tidy copy")
    #expect(copy?.template == "Tidy up:\n\n{{transcript}}")
    #expect(copy?.id != active.id)
    #expect(environment.settings.prompts.count == 2)
    #expect(environment.selectedPromptID == active.id)
    #expect(environment.prompt(id: copy?.id ?? UUID()) != nil)
}

@Test @MainActor func duplicatePromptFallsBackToUntitledCopy() {
    let environment = TestEnvironment().make()
    let created = environment.addPrompt()
    var edited = created
    edited.name = ""
    environment.updatePrompt(edited)
    let copy = environment.duplicatePrompt(id: created.id)
    #expect(copy?.name == "Untitled copy")
}

@Test @MainActor func duplicateUnknownPromptReturnsNil() {
    let environment = TestEnvironment().make()
    let before = environment.addPrompt()
    environment.selectPrompt(id: before.id)
    #expect(environment.duplicatePrompt(id: UUID()) == nil)
    #expect(environment.settings.prompts.count == 1)
    #expect(environment.selectedPromptID == before.id)
}

@Test @MainActor func deletingNonActivePromptKeepsActivation() {
    let environment = TestEnvironment().make()
    let active = environment.addPrompt()
    environment.selectPrompt(id: active.id)
    let other = environment.duplicatePrompt(id: active.id)
    environment.deletePrompt(id: other?.id ?? UUID())
    #expect(environment.selectedPromptID == active.id)
    #expect(environment.prompt(id: active.id) != nil)
}

@Test @MainActor func promptRowPreviewsItsInstructions() {
    let prompt = PromptDefinition(name: "Cleanup", template: "\n Clean up my words.\n{{transcript}}")
    #expect(PromptsTab.rowSubtitle(prompt: prompt) == "Clean up my words.")
    #expect(PromptsTab.rowSubtitle(prompt: PromptDefinition(template: " \n")) == "No instructions yet")
}

@Test @MainActor func promptDisplayNameFallsBackToUntitled() {
    #expect(PromptsTab.displayName(PromptDefinition(name: "Cleanup")) == "Cleanup")
    #expect(PromptsTab.displayName(PromptDefinition(name: "")) == "Untitled")
}

@Test @MainActor func placeholderCaptionMatchesAppendBehavior() {
    #expect(
        PromptsTab.placeholderCaption(hasPlaceholder: true)
            == "Dictation replaces \(RewritePromptRenderer.placeholder).")
    #expect(
        PromptsTab.placeholderCaption(hasPlaceholder: false)
            == "No \(RewritePromptRenderer.placeholder) — dictation is added at the end.")
}

@Test @MainActor func inactiveUseLabelNamesTheLivePrompt() {
    #expect(PromptsTab.inactiveUseLabel(activeName: nil) == "Not in use")
    #expect(PromptsTab.inactiveUseLabel(activeName: "Cleanup") == "Cleanup is in use")
}

@Test @MainActor func editingTargetPrefersStoredThenActiveThenFirst() {
    let first = PromptDefinition(name: "first", order: 0)
    let second = PromptDefinition(name: "second", order: 1)
    let prompts = [first, second]
    #expect(PromptsTab.editingTarget(stored: second.id, prompts: prompts, activeID: first.id) == second.id)
    #expect(PromptsTab.editingTarget(stored: nil, prompts: prompts, activeID: first.id) == first.id)
    #expect(PromptsTab.editingTarget(stored: UUID(), prompts: prompts, activeID: first.id) == first.id)
    #expect(PromptsTab.editingTarget(stored: nil, prompts: prompts, activeID: nil) == first.id)
    #expect(PromptsTab.editingTarget(stored: nil, prompts: [], activeID: first.id) == nil)
}

@Test @MainActor func movePromptShiftsByDeltaAndRenormalizesOrder() {
    let environment = TestEnvironment().make()
    let first = environment.addPrompt()
    let second = environment.addPrompt()
    let third = environment.addPrompt()
    #expect(environment.sortedPrompts.map(\.id) == [first.id, second.id, third.id])
    environment.movePrompt(id: first.id, delta: 1)
    #expect(environment.sortedPrompts.map(\.id) == [second.id, first.id, third.id])
    #expect(environment.sortedPrompts.map(\.order) == [0, 1, 2])
    environment.movePrompt(id: first.id, delta: -1)
    #expect(environment.sortedPrompts.map(\.id) == [first.id, second.id, third.id])
    environment.movePrompt(id: first.id, delta: -1)
    #expect(environment.sortedPrompts.map(\.id) == [first.id, second.id, third.id])
    environment.movePrompt(id: third.id, delta: 1)
    #expect(environment.sortedPrompts.map(\.id) == [first.id, second.id, third.id])
}

@Test @MainActor func updatePromptPersistsEditsWithoutStealingActivation() {
    let fixture = TestEnvironment()
    let environment = fixture.make()
    let created = environment.addPrompt()
    environment.selectPrompt(id: created.id)
    var edited = created
    edited.name = "Cleanup"
    edited.template = "Tidy:\n\n{{transcript}}"
    environment.updatePrompt(edited)
    #expect(environment.prompt(id: created.id)?.name == "Cleanup")
    #expect(environment.prompt(id: created.id)?.template == "Tidy:\n\n{{transcript}}")
    #expect(environment.selectedPromptID == created.id)
    environment.updatePrompt(PromptDefinition(id: UUID(), name: "ghost"))
    #expect(environment.settings.prompts.count == 1)
    #expect(environment.prompt(id: created.id)?.name == "Cleanup")
    let relaunched = fixture.make()
    #expect(relaunched.prompt(id: created.id)?.template == "Tidy:\n\n{{transcript}}")
    #expect(relaunched.selectedPromptID == created.id)
}

@Test @MainActor func sortedPromptsOrdersByOrderThenStableID() throws {
    let environment = TestEnvironment().make()
    let highID = try #require(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))
    let lowID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let high = PromptDefinition(id: highID, name: "high", order: 0)
    let low = PromptDefinition(id: lowID, name: "low", order: 0)
    let later = PromptDefinition(name: "later", order: 1)
    var settings = AppSettings.defaults
    settings.prompts = [high, later, low]
    environment.saveSettings(settings)
    #expect(environment.sortedPrompts.map(\.name) == ["low", "high", "later"])
}

@Test @MainActor func movePromptsMatchesListOnMove() {
    let environment = TestEnvironment().make()
    let first = environment.addPrompt()
    let second = environment.addPrompt()
    let third = environment.addPrompt()
    environment.selectPrompt(id: first.id)
    environment.movePrompts(from: IndexSet(integer: 0), to: 3)
    #expect(environment.sortedPrompts.map(\.id) == [second.id, third.id, first.id])
    #expect(environment.sortedPrompts.map(\.order) == [0, 1, 2])
    #expect(environment.selectedPromptID == first.id)
}

@Test @MainActor func customFieldTagMatchesCoreContract() {
    let custom = ConfigFieldType.enumAllowingCustom(cases: ["muse-voice-transcribe-1.0"])
    #expect(
        custom.pickerSelection(for: "future-model", customTag: EnumAllowingCustomField.customTag)
            == EnumAllowingCustomField.customTag)
    #expect(
        custom.pickerSelection(
            for: "muse-voice-transcribe-1.0", customTag: EnumAllowingCustomField.customTag)
            == "muse-voice-transcribe-1.0")
}

@Test func clearingCustomDraftKeepsStoredValue() {
    // A blank draft (cleared mid-edit) leaves the stored value untouched
    // instead of snapping back to the descriptor default.
    #expect(EnumAllowingCustomField.storedValue(forCustomDraft: "", current: "my-model") == "my-model")
    #expect(EnumAllowingCustomField.storedValue(forCustomDraft: "  ", current: "my-model") == "my-model")
    #expect(EnumAllowingCustomField.storedValue(forCustomDraft: "new-model", current: "my-model") == "new-model")
    #expect(EnumAllowingCustomField.storedValue(forCustomDraft: " padded ", current: "my-model") == "padded")
}

@Test @MainActor func providerKeyCheckingHasExactlyOneUncheckedAndOneCheckingString() {
    #expect(ProviderPresentation.uncheckedKeyTitle == "API key not checked")
    #expect(ProviderPresentation.checkingKeyTitle == "Checking API key…")
    #expect(ProviderPresentation.keyLabel(.notLoaded) == ProviderPresentation.uncheckedKeyTitle)
    #expect(ProviderPresentation.keyLabel(.loading) == ProviderPresentation.checkingKeyTitle)
    #expect(ProviderPresentation.keyLabel(.missing) == "Needs API key")
    #expect(ProviderPresentation.keyLabel(.saved) == "Key saved")
    #expect(ProviderPresentation.keyLabel(.unavailable("locked")) == "Keychain unavailable")
}
