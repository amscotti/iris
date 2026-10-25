import AppKit
import Foundation
import ServiceManagement
import os

/// Native launch-at-login operations, invoked through application commands.
enum LoginItem {
    private static let logger = Logger(subsystem: AppIdentity.identifier, category: "login-item")
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
    @discardableResult static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            logger.error("Launch at Login change failed: \(error.localizedDescription, privacy: .public)")
            return "Launch at Login could not be \(enabled ? "enabled" : "disabled"). \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return nil
    }
}

/// Waits for the old process to exit before reopening its real app bundle.
enum AppRelauncher {
    @MainActor static var canRelaunch: Bool {
        isRelaunchableBundle(path: Bundle.main.bundleURL.path, pathExtension: Bundle.main.bundleURL.pathExtension)
    }
    static func isRelaunchableBundle(path: String, pathExtension: String) -> Bool {
        pathExtension == "app" && !path.contains("/AppTranslocation/")
    }
    @MainActor static func relaunch() {
        guard canRelaunch else {
            NSApplication.shared.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = shellArguments(
            bundlePath: Bundle.main.bundleURL.path, pid: ProcessInfo.processInfo.processIdentifier)
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
    static func shellArguments(bundlePath: String, pid: Int32) -> [String] {
        [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", bundlePath,
            String(pid),
        ]
    }
}
