import AppKit
import SwiftUI

/// Owns the live graph and drives the menu bar, the pill, and permissions.
///
/// Hold the configured hotkey to dictate: audio streams while held, and the
/// finalized transcript lands at the cursor on release. The default hotkey
/// is hold Right-Option; the Fn key is not offered (the OS intercepts it
/// unreliably for this purpose).
@main
struct IrisApp: App {
    @State private var environment: AppEnvironment
    private let settingsPreview: Bool

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        #if DEBUG
            let preview = ProcessInfo.processInfo.arguments.contains("--preview-settings")
            let environment = preview ? SettingsPreview.makeEnvironment() : AppComposition.liveEnvironment()
        #else
            let preview = false
            let environment = AppComposition.liveEnvironment()
        #endif
        settingsPreview = preview
        _environment = State(initialValue: environment)
        // No quit-time teardown: process exit releases the microphone, the
        // hotkey monitors, and sockets, and settings/Keychain writes are
        // synchronous. Async work scheduled from `willTerminate` never runs
        // (exit comes first), and deferring quit with `.terminateLater` hangs
        // when `terminate` is called from a main-queue context.
        Task { @MainActor [environment] in
            if preview {
                environment.menuSymbol = "gearshape"
                environment.statusLine = "Settings preview — changes stay in memory"
                #if DEBUG
                    await SettingsPreview.start(environment)
                #endif
            } else {
                await environment.start()
            }
        }
    }

    var body: some Scene {
        // Label closure form: the title API does not reliably re-render the
        // status icon live on every macOS release, and the menu-bar icon is
        // the app's primary state surface (recording / restart needed).
        MenuBarExtra {
            MenuBarContent()
                .environment(environment)
        } label: {
            Label(
                settingsPreview ? "Iris Preview" : "Iris",
                systemImage: environment.menuSymbol
            )
            .accessibilityValue(environment.statusLine)
        }
    }
}
