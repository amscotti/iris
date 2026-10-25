import IrisCore
import SwiftUI

struct PromptDetailEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var prompt: PromptDefinition
    var isActive: Bool
    var activeName: String?
    @Binding var focusName: Bool
    var onUse: () -> Void
    var onUseNone: () -> Void
    @FocusState private var nameFocused: Bool

    private var hasPlaceholder: Bool { prompt.template.contains(RewritePromptRenderer.placeholder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            templateEditor
            Divider()
            routingInfo
        }
        .onAppear { applyFocusIfNeeded() }
        .onChange(of: focusName) { _, shouldFocus in
            if shouldFocus { applyFocusIfNeeded() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $prompt.name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            HStack(spacing: 8) {
                if isActive {
                    Label("In use for dictation", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("Use None", action: onUseNone)
                } else {
                    Text(PromptsTab.inactiveUseLabel(activeName: activeName))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use for dictation", action: onUse)
                }
            }
        }
        .padding(16)
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Instructions").font(.headline)
                Spacer()
                Button("Insert \(RewritePromptRenderer.placeholder)") { insertPlaceholder() }
                    .disabled(hasPlaceholder)
            }
            TextEditor(text: $prompt.template)
                .accessibilityLabel("Instructions")
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                        .allowsHitTesting(false)
                }
            SettingsCaption(PromptsTab.placeholderCaption(hasPlaceholder: hasPlaceholder))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var routingInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if environment.registry.rewriter(for: ProviderID(environment.settings.providerName)) != nil {
                    SettingsCaption("Uses \(environment.settings.providerName)’s model and reasoning.")
                } else {
                    SettingsCaption("The active provider inserts your words without rewriting.")
                }
                Spacer()
                Button("Provider settings…") { environment.selectedSettingsTab = .providers }
                    .font(.caption)
            }
            SettingsCaption("If a rewrite fails, Iris inserts your original words.")
        }
        .padding(16)
    }

    private func applyFocusIfNeeded() {
        guard focusName else { return }
        focusName = false
        Task { @MainActor in nameFocused = true }
    }

    private func insertPlaceholder() {
        if prompt.template.isEmpty {
            prompt.template = RewritePromptRenderer.placeholder
        } else {
            prompt.template += "\n\n" + RewritePromptRenderer.placeholder
        }
    }
}
