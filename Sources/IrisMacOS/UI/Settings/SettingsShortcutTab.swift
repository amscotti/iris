import IrisCore
import SwiftUI

// MARK: - Hotkey

struct ShortcutTab: View {
    @Environment(AppEnvironment.self) private var environment

    static let keyOptions: [(name: String, keyCode: Int)] = [
        ("Right Option", HotkeyConfiguration.defaultKeyCode),
        ("Left Option", 58),
        ("Right Command", 54),
        ("Left Command", 55),
        ("Left Shift", 56),
        ("Right Shift", 60),
        ("Left Control", 59),
        ("Right Control", 62),
    ]

    /// Keys that tend to fight system or app shortcuts.
    static func conflictWarning(for keyCode: Int) -> String? {
        switch keyCode {
        case 54, 55:
            return "Command keys often collide with shortcuts such as Spotlight. Right Option is the default."
        case 56, 60:
            return "Shift keys can collide with typing modifiers. Right Option is the default."
        case 58, 61:
            return "Option still types accents and symbols: Iris dictates only when it is held on its own."
        default:
            return nil
        }
    }

    static func tryItMessage(requiresRelaunch: Bool) -> String {
        requiresRelaunch
            ? "Iris is waiting for a restart; dictation is paused until then."
            : "Place the cursor in a text field in another app, then use your shortcut."
    }

    /// True when the persisted key code has no matching preset row (e.g. a
    /// legacy or hand-edited payload). The Picker then shows a fallback row
    /// so the current value stays visible and keepable.
    static func isKnownKeyCode(_ keyCode: Int) -> Bool {
        keyOptions.contains(where: { $0.keyCode == keyCode })
    }

    var body: some View {
        SettingsPane(title: "Keyboard shortcut", subtitle: "Dictate from the app you’re already using.") {
            Form {
                Section("Start dictation") {
                    Picker("Key", selection: environment.binding(for: \.hotkey.keyCode)) {
                        ForEach(Self.keyOptions, id: \.keyCode) { option in
                            Text(option.name).tag(option.keyCode)
                        }
                        if !Self.isKnownKeyCode(environment.settings.hotkey.keyCode) {
                            Text("Current key (\(environment.settings.hotkey.keyCode))")
                                .tag(environment.settings.hotkey.keyCode)
                        }
                    }
                    Picker("Behavior", selection: environment.binding(for: \.hotkey.mode)) {
                        Text("Hold to talk").tag(HotkeyConfiguration.Mode.hold)
                        Text("Press to start / stop").tag(HotkeyConfiguration.Mode.toggle)
                    }
                    .pickerStyle(.radioGroup)
                    SettingsCaption(
                        environment.settings.hotkey.mode == .hold
                            ? "Hold the key while you speak. Release it to insert your words."
                            : "Press once to start recording. Press again to stop and insert your words.")
                    if let warning = Self.conflictWarning(for: environment.settings.hotkey.keyCode) {
                        Label(warning, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Try it") {
                    Label(
                        Self.tryItMessage(requiresRelaunch: environment.requiresRelaunch),
                        systemImage: environment.requiresRelaunch
                            ? "arrow.triangle.2.circlepath" : "text.cursor")
                    SettingsCaption("Microphone and Accessibility access must be allowed in Permissions.")
                }
            }
            .formStyle(.grouped)
        }
    }
}
