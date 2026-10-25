import IrisCore
import SwiftUI

/// All shared prompt text uses the model and reasoning of the active provider.
/// Editing a backup provider changes only that provider's saved choices.
struct ProviderRewriteOptions: View {
    @Environment(AppEnvironment.self) private var environment
    let providerName: String

    var body: some View {
        if let descriptor = environment.registry.rewriter(for: ProviderID(providerName))?.descriptor {
            Section("Rewrite prompts") {
                EnumAllowingCustomField(
                    field: ConfigField(
                        key: ProviderConfiguration.Key.rewriteModel, label: "Model",
                        type: .enumAllowingCustom(cases: descriptor.modelPresets), defaultValue: descriptor.defaultModel
                    ),
                    cases: descriptor.modelPresets,
                    value: value(for: ProviderConfiguration.Key.rewriteModel, default: descriptor.defaultModel))
                Picker("Reasoning", selection: effort(for: descriptor)) {
                    ForEach(descriptor.effortCases, id: \.self) { effort in
                        Text(Self.effortTitle(effort, descriptor: descriptor)).tag(effort)
                    }
                }
                SettingsCaption(descriptor.effortCaption)
                HStack(alignment: .firstTextBaseline) {
                    SettingsCaption("Used by all prompts when \(providerName) is active.")
                    Spacer()
                    Button("Edit prompt text…") { environment.selectedSettingsTab = .prompts }
                        .font(.caption)
                }
            }
        }
    }

    private func value(for key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { environment.settings.providerConfigs[providerName]?[key] ?? defaultValue },
            set: { environment.setProviderValue(key: key, value: $0, provider: providerName) })
    }

    private func effort(for descriptor: RewriteDescriptor) -> Binding<PromptEffort> {
        let stored = value(for: ProviderConfiguration.Key.rewriteEffort, default: descriptor.defaultEffort.rawValue)
        return Binding(
            get: { descriptor.coercedEffort(PromptEffort(rawValue: stored.wrappedValue)) },
            set: { stored.wrappedValue = $0.rawValue })
    }

    static func effortTitle(_ effort: PromptEffort, descriptor: RewriteDescriptor) -> String {
        let title = effort == .xhigh ? "Extra high" : effort.rawValue.capitalized
        return effort == descriptor.defaultEffort ? "\(title) (fastest)" : title
    }
}
