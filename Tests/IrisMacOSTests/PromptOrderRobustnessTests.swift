import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func extremePersistedPromptOrderDoesNotTrapWhenAdding() {
    let controller = SettingsController(
        persistence: TestSettingsStore(), registry: ProviderRegistry(), defaults: .defaults)
    controller.save(AppSettings(prompts: [PromptDefinition(order: Int.max)]))

    let added = controller.addPrompt()

    #expect(added.order == Int.max)
    #expect(controller.settings.prompts.count == 2)
}
