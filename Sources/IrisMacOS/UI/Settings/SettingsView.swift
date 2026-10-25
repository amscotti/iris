import AppKit
import Combine
import IrisCore
import SwiftUI

/// The native preference toolbar lives on SettingsWindowController. Keeping
/// pane content here avoids creating a second SwiftUI-managed settings window.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingRecovery = false

    var body: some View {
        VStack(spacing: 0) {
            if Self.showsStatusBanner(
                loadIssue: environment.settingsLoadIssue, saveError: environment.settingsSaveError,
                requiresRelaunch: environment.requiresRelaunch,
                startupBlockers: environment.menuStartupBlockers)
            {
                VStack(spacing: 6) {
                    if environment.requiresRelaunch {
                        Label("Restart Iris to resume dictation", systemImage: "arrow.triangle.2.circlepath")
                        if environment.canRestartApplication {
                            Button("Restart Iris") { environment.restartApplication() }
                        }
                    }
                    if let error = environment.settingsSaveError {
                        Label(error, systemImage: "exclamationmark.triangle")
                    }
                    if let issue = environment.settingsLoadIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                        HStack {
                            Button("Retry reading settings") { environment.retrySettingsLoad() }
                            if environment.canRecoverSettings {
                                Button("Back up and use defaults…") { confirmingRecovery = true }
                                    .confirmationDialog(
                                        "Replace your settings with the defaults?", isPresented: $confirmingRecovery
                                    ) {
                                        Button("Back Up and Use Defaults", role: .destructive) {
                                            environment.recoverSettings()
                                        }
                                    } message: {
                                        Text(
                                            "Prompts and options reset to their defaults. Iris first keeps a "
                                                + "secret-safe recovery copy when possible. If damaged data cannot "
                                                + "be safely redacted, only a placeholder is kept—not the original bytes."
                                        )
                                    }
                            }
                        }
                    }
                    if let startupSummary = Self.startupBlockerSummary(environment.menuStartupBlockers) {
                        Label(startupSummary, systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4))
            }
            Group {
                switch environment.selectedSettingsTab {
                case .appearance: AppearanceTab()
                case .providers: ProvidersTab()
                case .shortcut: ShortcutTab()
                case .permissions: PermissionsTab()
                case .prompts: PromptsTab()
                case .typing: TypingTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: SettingsPage.width, minHeight: SettingsPage.height)
        .onAppear {
            environment.refreshPermissions()
            announceStatusBanner()
        }
        .onChange(of: bannerAnnouncement) { _, announcement in
            if let announcement { AccessibilityAnnouncement.post(announcement) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            environment.refreshPermissions()
        }
        .onExitCommand { environment.settingsWindowController?.close() }
    }

    private var bannerAnnouncement: String? {
        Self.statusBannerAnnouncement(
            loadIssue: environment.settingsLoadIssue, saveError: environment.settingsSaveError,
            requiresRelaunch: environment.requiresRelaunch,
            startupBlockers: environment.menuStartupBlockers)
    }

    private func announceStatusBanner() {
        if let bannerAnnouncement { AccessibilityAnnouncement.post(bannerAnnouncement) }
    }

    /// Whether the status banner above the panes is shown: load/save trouble,
    /// a restart-blocked runtime, or unfinished setup that silent panes must not hide.
    nonisolated static func showsStatusBanner(
        loadIssue: String?, saveError: String?, requiresRelaunch: Bool,
        startupBlockers: [StartupReadiness.MissingItem] = []
    ) -> Bool {
        loadIssue != nil || saveError != nil || requiresRelaunch || !startupBlockers.isEmpty
    }

    /// VoiceOver text for every condition represented in the banner.
    nonisolated static func statusBannerAnnouncement(
        loadIssue: String?, saveError: String?, requiresRelaunch: Bool,
        startupBlockers: [StartupReadiness.MissingItem] = []
    ) -> String? {
        var parts: [String] = []
        if requiresRelaunch { parts.append("Restart Iris to resume dictation.") }
        if let saveError { parts.append(saveError) }
        if let loadIssue { parts.append(loadIssue) }
        if let startupSummary = startupBlockerSummary(startupBlockers) { parts.append(startupSummary) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    nonisolated static func startupBlockerSummary(
        _ startupBlockers: [StartupReadiness.MissingItem]
    ) -> String? {
        guard !startupBlockers.isEmpty else { return nil }
        return "Setup needed: \(startupBlockers.map(\.label).joined(separator: ", "))."
    }
}

/// One default and minimum window size for every tab, so switching panes
/// does not resize Settings. People can enlarge the window when text or
/// content needs more room; panes scroll internally at the minimum size.
enum SettingsPage {
    static let width: CGFloat = 780
    static let height: CGFloat = 560
}
