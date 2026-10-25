import Foundation
import IrisCore

/// Presentation exposes prompt commands; their mutations belong to the settings owner.
@MainActor
extension AppEnvironment {
    public var sortedPrompts: [PromptDefinition] { settingsController.sortedPrompts }
    public var selectedPromptID: UUID? { settingsController.selectedPromptID }
    public var selectedPrompt: PromptDefinition? { settingsController.selectedPrompt }
    public func prompt(id: UUID) -> PromptDefinition? { settingsController.prompt(id: id) }
    public func updatePrompt(_ prompt: PromptDefinition) { settingsController.updatePrompt(prompt) }
    public func selectPrompt(id: UUID?) { settingsController.selectPrompt(id: id) }
    @discardableResult public func addPrompt() -> PromptDefinition { settingsController.addPrompt() }
    @discardableResult public func addExamplePrompt() -> PromptDefinition { settingsController.addExamplePrompt() }
    @discardableResult public func duplicatePrompt(id: UUID) -> PromptDefinition? {
        settingsController.duplicatePrompt(id: id)
    }
    public func deletePrompt(id: UUID) { settingsController.deletePrompt(id: id) }
    public func movePrompt(id: UUID, delta: Int) { settingsController.movePrompt(id: id, delta: delta) }
    public func movePrompts(from offsets: IndexSet, to offset: Int) {
        settingsController.movePrompts(from: offsets, to: offset)
    }
    public static func examplePrompt(order: Int) -> PromptDefinition { SettingsController.examplePrompt(order: order) }
}
