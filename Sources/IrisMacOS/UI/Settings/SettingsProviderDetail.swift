import AppKit
import IrisCore
import SwiftUI

struct ProviderDetail: View {
    @Environment(AppEnvironment.self) private var environment
    let providerName: String
    @Binding var keyDraft: String

    private var isActive: Bool { environment.settings.providerName == providerName }
    private var keyState: ProviderKeyState { environment.credentials.state(for: providerName) }
    private var hasKey: Bool { keyState == .saved }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(providerName).font(.title3.weight(.semibold))
                        SettingsCaption(
                            environment.registry.provider(for: ProviderID(providerName))?.information.serviceName
                                ?? "Speech to text")
                    }
                    Spacer()
                    if isActive {
                        SettingsStatus(
                            title: activeKeyTitle, symbol: activeKeySymbol, tint: activeKeyTint)
                    } else {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("Use \(providerName)") { environment.setProvider(providerName) }
                                .disabled(!hasKey)
                                .help(useHelp)
                            if !hasKey {
                                SettingsCaption(useHelp)
                            }
                        }
                    }
                }
            }
            if isActive, let message = environment.lastDictationError {
                Section("Last dictation issue") {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Connection") {
                ProviderKeyEditor(providerName: providerName, draft: $keyDraft)
            }
            ProviderOptions(providerName: providerName)
            ProviderRewriteOptions(providerName: providerName)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeKeyTitle: String {
        switch keyState {
        case .saved: return "In use"
        case .unavailable: return "Keychain unavailable"
        case .loading, .notLoaded: return ProviderPresentation.keyLabel(keyState)
        case .missing: return "Needs API key"
        }
    }

    private var activeKeySymbol: String {
        switch keyState {
        case .saved: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.triangle"
        case .loading, .notLoaded: return "ellipsis.circle"
        case .missing: return "key"
        }
    }

    private var activeKeyTint: Color {
        switch keyState {
        case .saved: return .accentColor
        case .loading, .notLoaded: return .secondary
        case .unavailable, .missing: return .orange
        }
    }

    private var useHelp: String {
        ProviderPresentation.useHelp(providerName: providerName, state: keyState)
    }
}

private struct ProviderKeyEditor: View {
    @Environment(AppEnvironment.self) private var environment
    let providerName: String
    @Binding var draft: String
    @State private var editing = false
    @State private var saving = false
    @State private var confirmingRemoval = false
    @State private var clipboardMessage: String?
    @FocusState private var keyFocused: Bool

    private var keyState: ProviderKeyState { environment.credentials.state(for: providerName) }
    private var hasKey: Bool { keyState == .saved }
    private var showsEditor: Bool { !hasKey || editing || !draft.isEmpty }
    private var connection: ProviderConnectionState { environment.connections.state(for: providerName) }
    private var testConnectionDisabledReason: String? {
        if case .unavailable = keyState { return "Unlock Keychain before testing the connection." }
        if keyState == .loading || keyState == .notLoaded {
            return "Wait until Iris finishes checking the API key."
        }
        return ProviderPresentation.testConnectionDisabledReason(
            hasKey: hasKey, showsEditor: showsEditor, saving: saving)
    }
    private var testConnectionDisabled: Bool {
        connection == .checking || testConnectionDisabledReason != nil
    }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var information: ProviderInformation {
        environment.registry.provider(for: ProviderID(providerName))?.information
            ?? ProviderInformation(serviceName: "Speech to text", accountName: providerName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if keyState == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(ProviderPresentation.keyLabel(keyState)).foregroundStyle(.secondary)
                }
            } else if case .unavailable(let message) = keyState {
                SettingsCaption(message)
                Button("Try again") {
                    Task { @MainActor in await environment.loadProviderCredentials(providerName, retry: true) }
                }
            } else if showsEditor {
                keyEntry
            } else {
                HStack {
                    Label("API key saved", systemImage: "key.fill")
                    Spacer()
                    Button("Replace…") {
                        editing = true
                        keyFocused = true
                    }
                    Button("Remove…", role: .destructive) { confirmingRemoval = true }
                }
            }
            if let message = environment.credentialErrors[providerName] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .firstTextBaseline) {
                SettingsCaption("Saved keys stay in your Mac’s Keychain.")
                Spacer()
                if let url = information.apiKeyURL {
                    Link("Get \(information.accountName) API key ↗", destination: url)
                        .font(.caption)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button(connection == .checking ? "Testing…" : "Test connection") {
                    Task { @MainActor in await environment.testProviderConnection(providerName) }
                }
                .disabled(testConnectionDisabled)
                .help(
                    testConnectionDisabledReason
                        ?? "Checks speech access without recording or sending microphone audio.")
                if connection == .checking {
                    ProgressView().controlSize(.small)
                } else if connection == .connected {
                    Label {
                        Text("Speech connection verified")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.caption)
                } else if connection == .notChecked {
                    Text("Not tested").font(.caption).foregroundStyle(.secondary)
                }
            }
            if connection != .checking, let reason = testConnectionDisabledReason {
                SettingsCaption(reason)
            }
            if case .failed(let message) = connection {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .onChange(of: connection) { _, newState in
            if let announcement = ProviderPresentation.connectionAnnouncement(
                providerName: providerName, state: newState)
            {
                AccessibilityAnnouncement.post(announcement)
            }
        }
        .onChange(of: environment.credentialErrors[providerName]) { _, message in
            if let message { AccessibilityAnnouncement.post(message) }
        }
        .disabled(saving)
        .confirmationDialog("Remove the \(providerName) API key?", isPresented: $confirmingRemoval) {
            Button("Remove key", role: .destructive) { removeKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to add a key again to use \(providerName).")
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("\(information.accountName) API key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .privacySensitive()
                .onSubmit { if !trimmedDraft.isEmpty && !saving { saveKey() } }
            HStack {
                Button(saving ? "Saving…" : "Save key") { saveKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedDraft.isEmpty || saving)
                Button("Paste") {
                    clipboardMessage = ProviderKeyDraftActions.paste(
                        $draft, from: environment.readClipboardTextResult())
                    if let clipboardMessage {
                        AccessibilityAnnouncement.post(clipboardMessage)
                    } else {
                        keyFocused = true
                    }
                }
                .disabled(saving)
                Spacer()
                if hasKey {
                    Button("Cancel") {
                        draft = ""
                        editing = false
                        clipboardMessage = nil
                    }
                    .disabled(saving)
                }
            }
            if let clipboardMessage { SettingsCaption(clipboardMessage) }
        }
    }

    private func saveKey() {
        saving = true
        let binding = $draft
        Task { @MainActor in
            if await ProviderKeyDraftActions.save(
                binding,
                using: { value in
                    await environment.saveSecret(value, field: ProviderConfiguration.Key.apiKey, provider: providerName)
                })
            {
                editing = false
                clipboardMessage = nil
            }
            saving = false
        }
    }

    private func removeKey() {
        saving = true
        Task { @MainActor in
            if await environment.clearSecret(field: ProviderConfiguration.Key.apiKey, provider: providerName) {
                draft = ""
                editing = false
            }
            saving = false
        }
    }
}

/// The editor and its regression tests share the actual draft transition:
/// failure preserves the bound draft; only successful persistence clears it.
@MainActor
enum ProviderKeyDraftActions {
    /// Applies a clipboard read to the editor draft. Returns the message
    /// to show and announce when no usable key was pasted.
    static func paste(_ draft: Binding<String>, from read: ClipboardTextRead) -> String? {
        switch read {
        case .unavailable:
            return "Clipboard is busy. Try Paste again."
        case .concealed:
            return "The clipboard contains a concealed password. Copy an API key explicitly instead."
        case .empty:
            return "Copy an API key first, then choose Paste."
        case .text(let text):
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "Copy an API key first, then choose Paste." }
            draft.wrappedValue = value
            return nil
        }
    }

    static func save(_ draft: Binding<String>, using save: @MainActor (String) async -> Bool) async -> Bool {
        let value = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, await save(value) else { return false }
        draft.wrappedValue = ""
        return true
    }
}

enum ProviderPresentation {
    /// The two key-check states, shared by the sidebar row, the detail
    /// badge, and the editor so one state never gets two wordings.
    static let uncheckedKeyTitle = "API key not checked"
    static let checkingKeyTitle = "Checking API key…"

    static func keyLabel(_ state: ProviderKeyState) -> String {
        switch state {
        case .notLoaded: return uncheckedKeyTitle
        case .loading: return checkingKeyTitle
        case .missing: return "Needs API key"
        case .saved: return "Key saved"
        case .unavailable: return "Keychain unavailable"
        }
    }

    static func useHelp(providerName: String, state: ProviderKeyState) -> String {
        switch state {
        case .saved: return "Use \(providerName) for dictation and rewrites"
        case .unavailable: return "Unlock Keychain before using \(providerName)"
        case .loading, .notLoaded: return keyLabel(state)
        case .missing: return "Save an API key first"
        }
    }

    static func testConnectionDisabledReason(hasKey: Bool, showsEditor: Bool, saving: Bool) -> String? {
        if saving { return "Wait for the API key to finish saving." }
        if !hasKey { return "Save an API key before testing the connection." }
        if showsEditor { return "Save or cancel the API key edit before testing." }
        return nil
    }

    static func connectionAnnouncement(providerName: String, state: ProviderConnectionState) -> String? {
        switch state {
        case .connected: return "\(providerName) speech connection verified."
        case .failed(let message): return "\(providerName) connection failed: \(message)"
        case .checking, .notChecked: return nil
        }
    }
}
