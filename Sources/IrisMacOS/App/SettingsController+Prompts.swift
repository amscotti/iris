import Foundation
import IrisCore
import SwiftUI

/// Rewrite-prompt management: every mutation uses the controller's save
/// boundary, which publishes a configuration change to the application.
///
/// Exactly one of None and the stored prompts is active. A nil selection
/// means None, the zero-LLM bypass. Prompts never combine.
@MainActor
extension SettingsController {
    /// Prompts in sidebar order.
    public var sortedPrompts: [PromptDefinition] {
        settings.prompts.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func prompt(id: UUID) -> PromptDefinition? {
        settings.prompts.first { $0.id == id }
    }

    /// The active prompt id, or nil when None is selected.
    public var selectedPromptID: UUID? {
        settings.selectedPromptID
    }

    /// The active prompt, or nil when None is selected.
    public var selectedPrompt: PromptDefinition? {
        settings.selectedPrompt
    }

    /// Replaces the prompt with the same id and persists. Unknown ids are
    /// ignored.
    public func updatePrompt(_ prompt: PromptDefinition) {
        var updated = settings
        guard let index = updated.prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        updated.prompts[index] = prompt
        save(updated)
    }

    /// Makes `id` the single active prompt (nil selects None) and
    /// persists. Unknown ids are ignored, so a stale pick never activates
    /// a missing prompt. A no-op when the selection is unchanged.
    public func selectPrompt(id: UUID?) {
        guard settings.selectedPromptID != id else { return }
        if let id, prompt(id: id) == nil { return }
        var updated = settings
        updated.selectedPromptID = id
        save(updated)
    }

    /// Adds a prompt with the default template (instructions followed by
    /// the transcript placeholder) without touching the selection, and
    /// returns it for editing. Activation happens only via selectPrompt.
    @discardableResult
    public func addPrompt() -> PromptDefinition {
        let created = PromptDefinition(
            name: "New prompt",
            template: PromptDefinition.defaultTemplate,
            order: nextPromptOrder)
        var updated = settings
        updated.prompts.append(created)
        save(updated)
        return created
    }

    /// Adds the sample cleanup prompt without touching the selection, so
    /// it never steals the active prompt.
    @discardableResult
    public func addExamplePrompt() -> PromptDefinition {
        let created = Self.examplePrompt(order: nextPromptOrder)
        var updated = settings
        updated.prompts.append(created)
        save(updated)
        return created
    }

    public static func examplePrompt(order: Int) -> PromptDefinition {
        return PromptDefinition(
            name: "Cleanup",
            template: "Remove filler words (ums, ahs, you knows) and false starts. Rewrite as clean, readable "
                + "sentences with proper grammar. Preserve the original meaning and wording wherever possible. "
                + "Reply with only the rewritten text and no commentary.\n\n{{transcript}}",
            order: order)
    }

    /// Copies the prompt as "<name> copy" without touching activation,
    /// and returns the copy for editing. Unknown ids return nil.
    @discardableResult
    public func duplicatePrompt(id: UUID) -> PromptDefinition? {
        guard let source = prompt(id: id) else { return nil }
        let base = source.name.isEmpty ? "Untitled" : source.name
        let copy = PromptDefinition(
            name: "\(base) copy",
            template: source.template,
            order: nextPromptOrder)
        var updated = settings
        updated.prompts.append(copy)
        save(updated)
        return copy
    }

    /// Deletes the prompt and persists. Deleting the active prompt
    /// returns the selection to None.
    public func deletePrompt(id: UUID) {
        var updated = settings
        updated.prompts.removeAll { $0.id == id }
        if updated.selectedPromptID == id {
            updated.selectedPromptID = nil
        }
        save(updated)
    }

    /// Moves the prompt by `delta` positions in sidebar order (±1), then
    /// renormalizes order values to the new sequence.
    public func movePrompt(id: UUID, delta: Int) {
        let sorted = sortedPrompts
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard sorted.indices.contains(target) else { return }
        movePrompts(from: IndexSet(integer: index), to: delta > 0 ? target + 1 : target)
    }

    /// Reorders prompts the way `List.onMove` reports (offsets → insertion
    /// index), then renormalizes order values to the new sequence.
    public func movePrompts(from offsets: IndexSet, to offset: Int) {
        var sorted = sortedPrompts
        sorted.move(fromOffsets: offsets, toOffset: offset)
        var updated = settings
        for (position, item) in sorted.enumerated() {
            if let slot = updated.prompts.firstIndex(where: { $0.id == item.id }) {
                updated.prompts[slot].order = position
            }
        }
        save(updated)
    }

    private var nextPromptOrder: Int {
        let largest = settings.prompts.map(\.order).max() ?? -1
        // Corrupt persisted orders must not turn Add/Duplicate into a trap.
        return largest == Int.max ? Int.max : largest + 1
    }
}
