#if DEBUG
    import AppKit
    import Foundation
    import IrisCore
    import IrisProviders

    /// Opt-in native smoke check. Runs only with --preview-settings and
    /// --preview-output=<directory>. Screenshots contain preview data; the
    /// lifecycle report records focus/policy facts, never credentials.
    @MainActor
    extension SettingsPreview {
        static func start(_ environment: AppEnvironment) async {
            let prefix = "--preview-output="
            guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
                environment.openSettingsWindow()
                return
            }
            let directory = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)), isDirectory: true)
            do {
                try await capture(environment, directory: directory)
            } catch {
                NSLog("Iris preview capture failed: %@", error.localizedDescription)
            }
        }

        private static func capture(_ environment: AppEnvironment, directory: URL) async throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(400))
            // First presentation is a fresh Settings action after launch,
            // just like choosing the menu item for the first time.
            environment.openSettingsWindow()
            try await Task.sleep(for: .milliseconds(300))
            guard let controller = environment.settingsWindowController, let window = controller.window else { return }
            var report: [String: Bool] = [
                "accessoryPolicy": NSApplication.shared.activationPolicy() == .accessory,
                "firstOpenIsKey": window.isKeyWindow,
                "firstOpenIsActive": NSApplication.shared.isActive,
                "firstOpenIsVisible": window.isVisible,
                "runningCodeSignatureIsValid": ApplicationImage.isCurrent(),
            ]
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            controller.close()
            report["closeHidesWindow"] = !window.isVisible
            _ = finder?.activate(options: [])
            try await Task.sleep(for: .milliseconds(200))
            report["otherAppWasActiveBeforeReopen"] = finder?.isActive == true
            environment.openSettingsWindow()
            try await Task.sleep(for: .milliseconds(400))
            report["reopenReusesWindow"] = controller.window === window
            report["reopenIsKey"] = window.isKeyWindow
            report["reopenIsActive"] = NSApplication.shared.isActive

            _ = finder?.activate(options: [])
            try await Task.sleep(for: .milliseconds(200))
            report["otherAppWasActiveBeforeRaise"] = finder?.isActive == true
            environment.openSettingsWindow()
            try await Task.sleep(for: .milliseconds(400))
            report["raiseExistingIsKey"] = window.isKeyWindow
            report["raiseExistingIsActive"] = NSApplication.shared.isActive

            for pane in SettingsTab.allCases {
                if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == pane.rawValue }),
                    let action = item.action
                {
                    NSApplication.shared.sendAction(action, to: item.target, from: item)
                }
                try await Task.sleep(for: .milliseconds(200))
                report["\(pane.rawValue)PaneKeepsFocus"] = window.isKeyWindow && NSApplication.shared.isActive
                try snapshot(window, to: directory.appendingPathComponent("iris-preview-\(pane.rawValue).png"))
            }
            report["providerChangeKeepsFocus"] = try await captureProviderStates(
                environment, window: window, directory: directory)
            report["oneSettingsWindow"] =
                NSApplication.shared.windows.filter {
                    $0.identifier == SettingsWindowController.windowIdentifier
                }.count == 1
            report["accessoryPolicyAfterInteractions"] = NSApplication.shared.activationPolicy() == .accessory
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("iris-preview-report.json"))
        }

        private static func captureProviderStates(
            _ environment: AppEnvironment, window: NSWindow, directory: URL
        ) async throws -> Bool {
            environment.selectedSettingsTab = .providers
            environment.setProvider(ProviderID.grok.name)
            try await Task.sleep(for: .milliseconds(200))
            try snapshot(window, to: directory.appendingPathComponent("iris-preview-grok-setup.png"))
            await environment.saveSecret("preview-only", field: "apiKey", provider: "Grok")
            await environment.testProviderConnection("Grok")
            try await Task.sleep(for: .milliseconds(200))
            try snapshot(window, to: directory.appendingPathComponent("iris-preview-grok-connected.png"))
            window.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .milliseconds(200))
            try snapshot(window, to: directory.appendingPathComponent("iris-preview-light.png"))
            window.appearance = nil
            return window.isKeyWindow && NSApplication.shared.isActive
        }

        private static func snapshot(_ window: NSWindow, to url: URL) throws {
            guard let view = window.contentView?.superview,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
