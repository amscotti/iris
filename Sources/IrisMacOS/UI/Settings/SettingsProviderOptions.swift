import IrisCore
import SwiftUI

/// Provider-specific options stay beside that provider's key, including when
/// it is a backup. Less common wire/model controls are disclosed on demand.
struct ProviderOptions: View {
    @Environment(AppEnvironment.self) private var environment
    let providerName: String

    private var descriptor: ConfigDescriptor? { environment.registry.descriptor(forName: providerName) }

    private var speechFields: [ConfigField] {
        return descriptor?.fields.filter {
            $0.isVisible && !RewriteConfiguration.settingKeys.contains($0.key) && $0.type != .secret
        } ?? []
    }

    private var primaryFields: [ConfigField] { speechFields.filter { !$0.advanced } }
    private var otherFields: [ConfigField] { speechFields.filter(\.advanced) }

    var body: some View {
        if !primaryFields.isEmpty {
            Section("Recognition") {
                ForEach(primaryFields, id: \.key) { option($0) }
            }
        }
        if !otherFields.isEmpty {
            Section {
                DisclosureGroup("Advanced options") {
                    ForEach(otherFields, id: \.key) { field in
                        option(field)
                    }
                    LabeledContent("Audio", value: "16 kHz · mono PCM")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func value(for field: ConfigField) -> Binding<String> {
        Binding(
            get: {
                // Bind the raw stored value. `displayValue(_:for:)` is render-only
                // per `DictationProvider` (it must round-trip and is never
                // persisted): collapsing it here would truncate multi-value
                // `languageBias` lists to their first entry on the next write.
                // Visible labels come from `ConfigField.displayName(for:)`
                // in `ProviderFieldRow`.
                environment.settings.providerConfigs[providerName]?[field.key] ?? field.defaultValue
            },
            set: { environment.setProviderValue(key: field.key, value: $0, provider: providerName) })
    }

    @ViewBuilder
    private func option(_ field: ConfigField) -> some View {
        ProviderFieldRow(field: field, value: value(for: field))
        if let hint = field.hint { SettingsCaption(hint) }
    }
}
