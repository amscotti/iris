import IrisCore
import SwiftUI

/// One provider descriptor field row. The settings section owns the bindings;
/// this view only renders the control matching the field type.
struct ProviderFieldRow: View {
    var field: ConfigField
    @Binding var value: String

    var body: some View {
        switch field.type {
        case .string:
            TextField(field.label, text: $value)
        case .enum(let cases):
            Picker(
                field.label,
                selection: Binding(
                    get: { effectiveSelection },
                    set: { value = $0 })
            ) {
                ForEach(cases, id: \.self) { option in
                    Text(field.displayName(for: option)).tag(option)
                }
                // A stored value that matches no case (hand-edited or from
                // an older build) stays selectable instead of rendering an
                // empty picker that silently rewrites on first use.
                if !selectionInCases(cases) {
                    Text("Current: \(effectiveSelection)").tag(effectiveSelection)
                }
            }
        case .enumAllowingCustom(let cases):
            EnumAllowingCustomField(field: field, cases: cases, value: $value)
        case .bool:
            Toggle(
                field.label,
                isOn: Binding(
                    get: {
                        let normalized =
                            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return normalized == "true" || normalized == "1" || normalized == "yes"
                    },
                    set: { value = $0 ? "true" : "false" })
            )
        case .secret:
            // Secrets never render as option rows: the provider's API key is
            // edited by `ProviderKeyEditor` and stored in the Keychain.
            EmptyView()
        }
    }
}

/// Picker with presets plus a free-form entry. The stored value is always the
/// real string; anything outside the presets renders as Custom with the text
/// field prefilled. Selected purely from the field type, so descriptors stay
/// generic across providers.
struct EnumAllowingCustomField: View {
    static let customTag = "__iris_custom__"

    var field: ConfigField
    var cases: [String]
    @Binding var value: String
    @State private var choosingCustom = false
    /// In-progress custom text. Clearing the field to retype must not
    /// snap the stored value back to the default mid-edit; only a
    /// non-blank draft is stored.
    @State private var customDraft: String?

    /// Value to store for an edited custom draft: the trimmed draft when
    /// it has content, otherwise the current stored value untouched.
    nonisolated static func storedValue(forCustomDraft draft: String, current: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? current : trimmed
    }

    private var effective: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? field.defaultValue : trimmed
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                choosingCustom ? Self.customTag : field.type.pickerSelection(for: effective, customTag: Self.customTag)
            },
            set: {
                // Choosing Custom keeps the current text; choosing a preset
                // stores that preset string directly.
                choosingCustom = $0 == Self.customTag
                if choosingCustom {
                    customDraft = value
                } else {
                    customDraft = nil
                    value = $0
                }
            })
    }

    private var showsCustom: Bool { selection.wrappedValue == Self.customTag }

    private var customText: Binding<String> {
        Binding(
            get: { customDraft ?? value },
            set: {
                // An empty custom entry must not persist "" (it would shadow
                // the descriptor default in `merged(with:)`), but clearing
                // the field also must not snap back to the default mid-edit:
                // keep the blank draft locally and store only real content.
                customDraft = $0
                value = Self.storedValue(forCustomDraft: $0, current: value)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(field.label, selection: selection) {
                ForEach(cases, id: \.self) { option in
                    Text(field.displayName(for: option)).tag(option)
                }
                Text("Custom…").tag(Self.customTag)
            }
            if showsCustom {
                TextField("Custom \(field.label.lowercased())", text: customText)
            }
        }
    }
}

extension ProviderFieldRow {
    /// The value the picker actually shows: stored when present, otherwise
    /// the field default.
    fileprivate var effectiveSelection: String {
        value.isEmpty ? field.defaultValue : value
    }

    /// True when the effective selection matches a picker case.
    fileprivate func selectionInCases(_ cases: [String]) -> Bool {
        cases.contains(effectiveSelection)
    }
}
