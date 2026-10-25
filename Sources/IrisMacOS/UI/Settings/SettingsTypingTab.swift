import IrisCore
import SwiftUI

/// Text insertion is independent of the speech provider. Recognition options
/// live in Providers, beside the service they configure.
struct TypingTab: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPane(title: "Text insertion", subtitle: "Choose how your words land at the cursor.") {
            Form {
                Section("Insertion method") {
                    Picker("Insert using", selection: environment.binding(for: \.insertMethod)) {
                        Text("Keystrokes").tag(AppSettings.InsertMethod.keystroke)
                        Text("Clipboard paste").tag(AppSettings.InsertMethod.paste)
                    }
                    SettingsCaption(
                        environment.settings.insertMethod == .keystroke
                            ? "Types directly into the focused app. Recommended for most apps."
                            : "Pastes the transcript with ⌘V, then restores your previous clipboard.")
                }
                Section("After each dictation") {
                    Toggle("Add a space", isOn: environment.binding(for: \.trailingSpace))
                    SettingsCaption("Continue typing or dictating without adding a space yourself.")
                    Toggle("Start a new line", isOn: environment.binding(for: \.trailingNewline))
                    SettingsCaption("Move to the next line after inserting the transcript.")
                }
            }
            .formStyle(.grouped)
        }
    }
}
