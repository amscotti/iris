import AppKit
import IrisCore
import SwiftUI

/// Menu-bar extra content. `IrisApp` owns the `MenuBarExtra` scene itself;
/// this view owns everything inside it (status, setup steps, Prompts menu,
/// Settings/About/Quit items) so the configuration surface stays beside Settings.
struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var loginError: String?

    var body: some View {
        Text(environment.statusLine)
        if Self.guidanceSection(
            requiresRelaunch: environment.requiresRelaunch,
            hasSettingsLoadIssue: environment.settingsLoadIssue != nil,
            startupLimited: environment.startupLimited,
            startupComplete: environment.hasFinishedInitialStartup) == .relaunch
        {
            // The status line already carries the restart sentence.
            if environment.canRestartApplication {
                Button("Restart Iris") { environment.restartApplication() }
            }
        } else if Self.guidanceSection(
            requiresRelaunch: environment.requiresRelaunch,
            hasSettingsLoadIssue: environment.settingsLoadIssue != nil,
            startupLimited: environment.startupLimited,
            startupComplete: environment.hasFinishedInitialStartup) == .setup
        {
            if environment.settingsLoadIssue != nil {
                Text("Settings could not be read")
                Button("Review Settings…") { environment.openSettingsWindow() }
            }
            if environment.startupLimited {
                // Each missing requirement is a direct route to its fix.
                ForEach(environment.menuStartupBlockers, id: \.self) { item in
                    Button(Self.setupStepLabel(for: item, providerName: environment.settings.providerName)) {
                        openSettings(
                            item == .apiKey || item == .keyAccess || item == .providerUnavailable
                                ? .providers : .permissions)
                    }
                }
            }
        } else {
            Text(environment.dictationHint)
        }
        if let message = environment.lastDictationError {
            Text(message)
        }
        if environment.canCancelDictation {
            Button("Cancel Dictation") { environment.cancelDictation() }
        }
        if environment.lastDictationText != nil {
            Button("Copy Last Dictation") { environment.copyLastDictationToClipboard() }
        }
        Divider()
        Button("Preview Dictation Indicator") {
            environment.pill.preview()
        }
        .disabled(environment.isTakeActive)
        Menu("Prompts") {
            // Picker renders native menu checkmarks (a conditional Image in
            // a Button label is dropped by the NSMenuItem bridge).
            Picker(
                "Active prompt",
                selection: Binding(
                    get: { environment.selectedPromptID },
                    set: { environment.selectPrompt(id: $0) }
                )
            ) {
                Text("None").tag(UUID?.none)
                ForEach(environment.sortedPrompts) { prompt in
                    Text(prompt.name.isEmpty ? "Untitled" : prompt.name)
                        .tag(UUID?.some(prompt.id))
                }
            }
            Divider()
            Button("Edit prompts…") { openSettings(.prompts) }
        }
        Button("Settings…") {
            environment.openSettingsWindow()
        }
        .keyboardShortcut(",", modifiers: .command)
        if environment.launchAtLoginNeedsApproval {
            Text("Approve Launch at Login in System Settings")
        }
        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { environment.launchAtLogin },
                set: {
                    if let message = environment.setLaunchAtLogin($0) { loginError = message }
                })
        )
        .disabled(environment.isSettingsPreview)
        .alert(
            "Launch at Login", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })
        ) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
        Button("About Iris") {
            NSApplication.shared.activate()
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }
        Divider()
        Button("Quit Iris") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    enum GuidanceSection: Equatable {
        case relaunch
        case setup
        case dictationHint
    }

    /// Relaunch outranks setup routing; load trouble and startup blockers
    /// share the setup section. Ordinary readiness shows the dictation hint.
    nonisolated static func guidanceSection(
        requiresRelaunch: Bool, hasSettingsLoadIssue: Bool, startupLimited: Bool,
        startupComplete: Bool = true
    ) -> GuidanceSection {
        if requiresRelaunch { return .relaunch }
        if !startupComplete { return .setup }
        return hasSettingsLoadIssue || startupLimited ? .setup : .dictationHint
    }

    /// The menu entry for one unmet requirement.
    static func setupStepLabel(for item: StartupReadiness.MissingItem, providerName: String) -> String {
        switch item {
        case .microphone: return "Allow Microphone Access…"
        case .microphoneBlockedByPolicy: return "Microphone blocked by system policy…"
        case .accessibility: return "Allow Accessibility Access…"
        case .apiKey: return "Add \(providerName) API Key…"
        case .keyAccess: return "Unlock Keychain for \(providerName)…"
        case .providerUnavailable: return "Choose a Speech Provider…"
        }
    }

    private func openSettings(_ tab: SettingsTab) {
        environment.selectedSettingsTab = tab
        environment.openSettingsWindow()
    }
}
