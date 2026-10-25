import IrisCore
import SwiftUI

/// Source-list plus detail. Highlight is the editing target; it does not
/// change which prompt rewrites dictation. Activation is the checkmark,
/// the detail's use control, or the menu bar.
struct PromptsTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editingID: UUID?
    @State private var pendingDeleteID: UUID?
    @State private var focusName = false

    static func rowSubtitle(prompt: PromptDefinition) -> String {
        let text = prompt.template.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "No instructions yet"
    }

    static func displayName(_ prompt: PromptDefinition) -> String {
        prompt.name.isEmpty ? "Untitled" : prompt.name
    }

    static func placeholderCaption(hasPlaceholder: Bool) -> String {
        if hasPlaceholder {
            return "Dictation replaces \(RewritePromptRenderer.placeholder)."
        }
        return "No \(RewritePromptRenderer.placeholder) — dictation is added at the end."
    }

    static func inactiveUseLabel(activeName: String?) -> String {
        if let activeName {
            return "\(activeName) is in use"
        }
        return "Not in use"
    }

    /// Stored row while it names a prompt, else the active prompt, else
    /// the first prompt in sidebar order, else nil.
    static func editingTarget(stored: UUID?, prompts: [PromptDefinition], activeID: UUID?) -> UUID? {
        if let stored, prompts.contains(where: { $0.id == stored }) {
            return stored
        }
        if let activeID, prompts.contains(where: { $0.id == activeID }) {
            return activeID
        }
        return prompts.first?.id
    }

    var body: some View {
        SettingsPane(
            title: "Rewrite prompts",
            subtitle: "Reusable text instructions. Model and reasoning come from the active provider."
        ) {
            VStack(spacing: 0) {
                HStack {
                    Picker(
                        "After dictation",
                        selection: Binding(
                            get: { environment.selectedPromptID }, set: { environment.selectPrompt(id: $0) })
                    ) {
                        Text("None — keep my words").tag(Optional<UUID>.none)
                        ForEach(environment.sortedPrompts) { prompt in
                            Text(Self.displayName(prompt)).tag(Optional(prompt.id))
                        }
                    }
                    .frame(maxWidth: 340)
                    Spacer()
                    SettingsCaption("Edits save automatically.")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                Divider()
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    detail
                }
            }
        }
        .confirmationDialog(
            "Delete this prompt?",
            isPresented: Binding(
                get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: {
                Self.editingTarget(
                    stored: editingID,
                    prompts: environment.sortedPrompts,
                    activeID: environment.selectedPromptID)
            },
            set: { editingID = $0 })
    }

    private var sidebar: some View {
        let prompts = environment.sortedPrompts
        return VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(prompts) { prompt in
                    let isActive = environment.selectedPromptID == prompt.id
                    let isFirst = prompts.first?.id == prompt.id
                    let isLast = prompts.last?.id == prompt.id
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.displayName(prompt))
                                .lineLimit(1)
                            Text(Self.rowSubtitle(prompt: prompt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if isActive {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .help("In use for dictation")
                                .accessibilityLabel("In use")
                        }
                    }
                    .frame(minHeight: 34)
                    .tag(prompt.id)
                    .contextMenu {
                        if isActive {
                            Button("Use None") { environment.selectPrompt(id: nil) }
                        } else {
                            Button("Use for dictation") { environment.selectPrompt(id: prompt.id) }
                        }
                        Divider()
                        Button("Duplicate") { duplicate(prompt.id) }
                        Button("Move Up") { environment.movePrompt(id: prompt.id, delta: -1) }
                            .disabled(isFirst)
                        Button("Move Down") { environment.movePrompt(id: prompt.id, delta: 1) }
                            .disabled(isLast)
                        Divider()
                        Button("Delete", role: .destructive) { pendingDeleteID = prompt.id }
                    }
                }
                .onMove { source, destination in
                    environment.movePrompts(from: source, to: destination)
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                pendingDeleteID = selectionBinding.wrappedValue
            }
            Divider()
            HStack(spacing: 4) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .help("Add prompt")
                .accessibilityLabel("Add prompt")
                Button {
                    pendingDeleteID = selectionBinding.wrappedValue
                } label: {
                    Image(systemName: "minus")
                }
                .help("Delete selected prompt")
                .accessibilityLabel("Delete selected prompt")
                .disabled(selectionBinding.wrappedValue == nil)
                Button {
                    if let id = selectionBinding.wrappedValue {
                        duplicate(id)
                    }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate selected prompt")
                .accessibilityLabel("Duplicate selected prompt")
                .disabled(selectionBinding.wrappedValue == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private var detail: some View {
        if environment.sortedPrompts.isEmpty {
            ContentUnavailableView {
                Label("No prompts", systemImage: "text.quote")
            } description: {
                Text(
                    "Start with a cleanup example or write your own instructions. Choose a prompt above when you want rewrites."
                )
            } actions: {
                Button("Add prompt") { add() }
                Button("Add cleanup example") { addExample() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let target = selectionBinding.wrappedValue, let binding = binding(for: target) {
            PromptDetailEditor(
                prompt: binding,
                isActive: environment.selectedPromptID == target,
                activeName: environment.selectedPrompt.map(Self.displayName),
                focusName: $focusName,
                onUse: { environment.selectPrompt(id: target) },
                onUseNone: { environment.selectPrompt(id: nil) }
            )
            .id(target)
        } else {
            Text("Select a prompt to edit it.")
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var deleteMessage: String {
        if let pendingDeleteID, let prompt = environment.prompt(id: pendingDeleteID) {
            let name = Self.displayName(prompt)
            if environment.selectedPromptID == pendingDeleteID {
                return "“\(name)” will be removed and dictation will use None."
            }
            return "“\(name)” will be removed."
        }
        return "This prompt will be removed."
    }

    private func binding(for id: UUID) -> Binding<PromptDefinition>? {
        guard environment.prompt(id: id) != nil else { return nil }
        return Binding(
            get: { environment.prompt(id: id) ?? PromptDefinition(id: id) },
            set: { environment.updatePrompt($0) })
    }

    private func add() {
        let created = environment.addPrompt()
        editingID = created.id
        focusName = true
    }

    private func addExample() {
        let created = environment.addExamplePrompt()
        editingID = created.id
    }

    private func duplicate(_ id: UUID) {
        guard let copy = environment.duplicatePrompt(id: id) else { return }
        editingID = copy.id
        focusName = true
    }

    private func confirmDelete() {
        if let pendingDeleteID {
            if editingID == pendingDeleteID {
                editingID = nil
            }
            environment.deletePrompt(id: pendingDeleteID)
        }
        self.pendingDeleteID = nil
    }
}
