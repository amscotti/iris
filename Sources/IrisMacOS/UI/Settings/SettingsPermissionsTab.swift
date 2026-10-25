import AppKit
import IrisCore
import SwiftUI

// MARK: - Permissions

struct PermissionsTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var reportLines: [String]?
    @State private var resetMessage: String?
    @State private var resetRunning = false
    @State private var confirmingReset = false

    var body: some View {
        SettingsPane(title: "Permissions", subtitle: "Two permissions let Iris hear you and type for you.") {
            Form {
                Section {
                    permissionHeading(
                        "Microphone", symbol: "mic",
                        statusTitle: environment.microphoneHeadingTitle,
                        allowed: environment.microphoneGranted)
                    SettingsCaption(
                        "Records your voice while you dictate. Audio is streamed to your provider, not saved to disk.")
                    if environment.runsUnbundled {
                        SettingsCaption(environment.unbundledPermissionGuidance)
                    } else if environment.microphoneNeedsPrompt {
                        Button("Allow microphone…") {
                            Task { @MainActor in
                                await environment.requestMicrophoneAccess()
                                refreshAll()
                            }
                        }
                    } else if environment.microphoneRestricted {
                        SettingsCaption(environment.microphoneGuidance)
                    } else if !environment.microphoneGranted {
                        Button("Open Microphone Settings…") {
                            environment.openMicrophoneSettings()
                        }
                    }
                }
                Section {
                    permissionHeading(
                        "Accessibility", symbol: "keyboard",
                        statusTitle: environment.accessibilityGranted ? "Allowed" : "Needs access",
                        allowed: environment.accessibilityGranted)
                    SettingsCaption("Detects your shortcut and inserts the transcript into the app you’re using.")
                    if !environment.accessibilityGranted {
                        Button("Open Accessibility Settings…") {
                            Task { @MainActor in
                                await environment.requestAccessibilityAccess()
                                refreshAll()
                            }
                        }
                        SettingsCaption("Turn on Iris under Privacy & Security → Accessibility, then return here.")
                    }
                }
                Section {
                    HStack {
                        SettingsCaption("Status refreshes when you return to Iris.")
                        Spacer()
                        Button("Refresh status") { refreshAll() }
                    }
                }
                troubleshooting
            }
            .formStyle(.grouped)
            .disabled(environment.permissionOperationInProgress)
        }
        .onAppear { refreshAll() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshAll()
        }
        .onChange(of: resetMessage) { _, message in
            if let message { AccessibilityAnnouncement.post(message) }
        }
    }

    private func permissionHeading(_ title: String, symbol: String, statusTitle: String, allowed: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            SettingsStatus(
                title: statusTitle,
                symbol: allowed ? "checkmark.circle.fill" : "exclamationmark.circle",
                tint: allowed ? .green : .orange)
        }
    }

    private var troubleshooting: some View {
        Section {
            DisclosureGroup("Advanced troubleshooting") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(environment.permissionResetExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(resetRunning ? "Resetting…" : "Reset permission state…") {
                            confirmingReset = true
                        }
                        .disabled(resetRunning)
                        .confirmationDialog("Reset Iris’s permissions?", isPresented: $confirmingReset) {
                            Button("Reset Permissions", role: .destructive) { runReset() }
                        } message: {
                            Text("Iris loses Microphone and Accessibility access until you allow both again.")
                        }
                        Spacer()
                        Button("Open System Settings") {
                            environment.openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                    if let resetMessage {
                        Text(resetMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !environment.permissionResetCommands.isEmpty {
                        ForEach(environment.permissionResetCommands, id: \.self) { command in
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("Copy reset commands") {
                            copyToClipboard(environment.permissionResetCommands.joined(separator: "\n"))
                        }
                        .font(.caption)
                    }
                    if let reportLines {
                        Divider()
                        Text("Diagnostics")
                            .font(.subheadline)
                        ForEach(reportLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func refreshAll() {
        environment.refreshPermissions()
        reportLines = environment.permissionDiagnosticLines()
        Task { await environment.checkStartupGate(openSettingsWhenBlocked: false) }
    }

    private func runReset() {
        resetRunning = true
        resetMessage = nil
        Task { @MainActor in
            let failure = await environment.resetPermissionAccess()
            environment.refreshPermissions()
            reportLines = environment.permissionDiagnosticLines()
            if let failure {
                resetMessage = failure
            } else {
                resetMessage =
                    "Reset finished. Allow microphone access above, then enable Iris in Accessibility settings."
            }
            resetRunning = false
        }
    }

    private func copyToClipboard(_ text: String) {
        _ = environment.copyTextToClipboard(text)
    }
}
