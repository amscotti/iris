import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import Foundation
import os

/// Microphone permission state with prompting, a System Settings deep link,
/// and explicit re-check entry points.
///
/// The owner refreshes on app activation and when settings open; recording
/// never starts while access is ungranted.
@MainActor
@Observable
public final class PermissionsManager {
    public enum MicrophoneStatus: String, Sendable, Equatable {
        case unknown
        case granted
        case denied
        case restricted

        public var label: String {
            switch self {
            case .unknown: return "Not determined"
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .restricted: return "Restricted"
            }
        }
    }

    public static let microphoneSettingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    public static let accessibilitySettingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    public private(set) var microphoneStatus: MicrophoneStatus = .unknown
    public private(set) var accessibilityGranted = false
    @ObservationIgnored private let suppliedSnapshot: (microphone: MicrophoneStatus, accessibility: Bool)?

    /// Guidance shown when the app runs outside its assembled bundle, where
    /// the system cannot attribute a microphone grant to the process.
    public static let unbundledGuidance =
        "Iris is running outside its app bundle, so macOS cannot show a microphone prompt. "
        + "Quit this copy and open Iris.app instead, then request access again."

    /// One-line reason shown above both permission rows, in plain words.
    public static let whyLine =
        "Iris types what you say into whatever app has focus. "
        + "The microphone hears you; Accessibility lets Iris press keys for you."

    /// One-line reason the reset exists: a stale system entry can block new
    /// prompts, and every developer rebuild invalidates Accessibility
    /// approval, so clearing the old entry lets the system ask again.
    public static let resetExplanation =
        "Local ad-hoc builds can require fresh privacy approvals. Quit Iris before replacing its app bundle. "
        + "If a permission entry stays stale after relaunching, reset this app’s permission state and request access again."

    public nonisolated static let tccToolPath = "/usr/bin/tccutil"

    public init() {
        suppliedSnapshot = nil
        refreshMicrophoneStatus()
        refreshAccessibilityStatus()
    }

    /// A supplied snapshot lets settings tests exercise readiness without
    /// depending on the host's privacy grants or requesting access.
    init(microphoneStatus: MicrophoneStatus, accessibilityGranted: Bool) {
        suppliedSnapshot = (microphoneStatus, accessibilityGranted)
        self.microphoneStatus = microphoneStatus
        self.accessibilityGranted = accessibilityGranted
    }

    public var microphoneGranted: Bool { microphoneStatus == .granted }

    /// True when launched as a raw binary without a bundle identifier. The
    /// privacy database keys grants by bundle, so a request from this state
    /// never produces a prompt or a grant entry.
    public var runsUnbundled: Bool { Bundle.main.bundleIdentifier == nil }

    /// Re-reads the current authorization state. Call on activation and when
    /// settings open. Reports denied only when the system reports denied; a
    /// never-prompted state stays unknown rather than denied. Reads through
    /// the macOS capture API rather than the iOS-first audio-application
    /// API so accessory apps see the same TCC state as System Settings.
    public func refreshMicrophoneStatus() {
        if let suppliedSnapshot {
            microphoneStatus = suppliedSnapshot.microphone
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = .granted
        case .denied: microphoneStatus = .denied
        case .restricted: microphoneStatus = .restricted
        case .notDetermined: microphoneStatus = .unknown
        @unknown default: microphoneStatus = .unknown
        }
    }

    /// Prompts for microphone access and returns the resulting grant. The
    /// accessory app activates first so the system prompt can present.
    @discardableResult
    public func requestMicrophone() async -> Bool {
        if suppliedSnapshot != nil { return microphoneGranted }
        // Outside an app bundle the privacy database cannot attribute a
        // grant, so the system never prompts. Report false without asking.
        if runsUnbundled { return false }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMicrophoneStatus()
        return granted
    }

    /// User-facing microphone state. Names what happened and how to fix it;
    /// never a bare denial.
    public var microphoneGuidance: String {
        switch microphoneStatus {
        case .granted:
            return "Granted — the microphone is ready."
        case .unknown:
            return "Not requested yet — choose Allow microphone… and accept the system prompt."
        case .denied:
            return
                "Turned off — open System Settings and turn Iris back on to dictate again. "
                + "If you never saw a system prompt, open Advanced troubleshooting below, "
                + "reset permission state, then choose Allow microphone… again."
        case .restricted:
            return
                "Blocked by system policy — the microphone is restricted on this Mac "
                + "and cannot be re-enabled in System Settings. Contact your administrator."
        }
    }

    /// User-facing Accessibility state. Names what happened and how to fix it.
    public var accessibilityGuidance: String {
        if accessibilityGranted {
            return "Granted — the hotkey and insertion are ready."
        }
        return "Not granted — choose Open Accessibility Settings… and turn Iris on to finish."
    }

    /// Opens System Settings at the Microphone privacy pane.
    public func openMicrophoneSettings() {
        guard suppliedSnapshot == nil else { return }
        guard let url = URL(string: Self.microphoneSettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-reads the Accessibility trust state. Call on activation and when
    /// settings open.
    public func refreshAccessibilityStatus() {
        if let suppliedSnapshot {
            accessibilityGranted = suppliedSnapshot.accessibility
            return
        }
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Prompts for Accessibility access (system dialog) and returns the
    /// trust state reported by the prompt call. An immediate `false` after
    /// prompting is expected: the user finishes the grant in System Settings,
    /// and the next `refreshAccessibilityStatus()` picks it up.
    @discardableResult
    public func requestAccessibility() -> Bool {
        if suppliedSnapshot != nil { return accessibilityGranted }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
        return trusted
    }

    /// Opens System Settings at the Accessibility privacy pane.
    public func openAccessibilitySettings() {
        guard suppliedSnapshot == nil else { return }
        guard let url = URL(string: Self.accessibilitySettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Raw reset commands for this app's bundle id, for display and copying.
    /// Empty when there is no bundle id to scope the reset to.
    public var resetCommandsForThisApp: [String] {
        Self.resetCommands(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Builds `tccutil reset` commands scoped to one bundle id only. Never
    /// broadens to the whole privacy database: a missing id yields no
    /// commands rather than an unscoped reset.
    public static func resetCommands(bundleIdentifier: String?) -> [String] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        return [
            "tccutil reset Microphone \(bundleIdentifier)",
            "tccutil reset Accessibility \(bundleIdentifier)",
        ]
    }

    /// Snapshot of why a grant may be failing, for the on-screen readout.
    /// Logs the same lines so a failure is explainable after the fact.
    public func diagnostics() -> PermissionDiagnostics {
        let rawName: String
        if let suppliedSnapshot {
            rawName = suppliedSnapshot.microphone.rawValue
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: rawName = "granted"
            case .denied: rawName = "denied"
            case .restricted: rawName = "restricted (system policy)"
            case .notDetermined: rawName = "not requested yet"
            @unknown default: rawName = "unknown"
            }
        }
        let usageText = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        let report = PermissionDiagnostics(
            runsUnbundled: runsUnbundled,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            microphoneUsageDescriptionPresent: usageText?.isEmpty == false,
            rawRecordPermission: rawName,
            microphoneStatus: microphoneStatus,
            accessibilityGranted: accessibilityGranted)
        Logger(subsystem: AppIdentity.identifier, category: "permissions").info(
            "Permission diagnostics: \(report.lines.joined(separator: " | "), privacy: .public)")
        return report
    }

    /// Per-service `tccutil` timeout so a hung helper cannot hold the reset UI open.
    nonisolated private static let resetTimeoutSeconds: Double = 10

    /// Clears this app's microphone and Accessibility entries, then re-reads
    /// state. Runs `tccutil` for the user's database (no sudo needed) scoped
    /// to this app's bundle id only. Returns nil on success, otherwise
    /// guidance naming the Terminal fallback.
    @discardableResult
    public func resetPermissionState() async -> String? {
        guard suppliedSnapshot == nil else { return "Permission resets are unavailable in the settings preview." }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return "There is no bundle id to reset. Quit this copy, open Iris.app, and try again."
        }
        guard FileManager.default.isExecutableFile(atPath: Self.tccToolPath) else {
            return
                "The automatic reset did not finish (\(Self.tccToolPath) is unavailable). Copy the commands below, run them in Terminal, "
                + "then allow access again with the buttons above."
        }
        let services = ["Microphone", "Accessibility"]
        let outcome = await Task.detached(priority: .userInitiated) { () -> ResetOutcome in
            var succeeded = true
            var details: [String] = []
            for service in services {
                let result = await Self.runReset(service: service, bundleIdentifier: bundleIdentifier)
                succeeded = succeeded && result.succeeded
                if let detail = result.detail { details.append("\(service): \(detail)") }
            }
            return ResetOutcome(succeeded: succeeded, details: details)
        }.value
        refreshMicrophoneStatus()
        refreshAccessibilityStatus()
        if outcome.succeeded {
            return nil
        }
        let detail = outcome.details.joined(separator: "; ")
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return "The automatic reset did not finish\(suffix). Copy the commands below, run them in Terminal, "
            + "then allow access again with the buttons above."
    }
}

extension PermissionsManager {
    private struct ResetOutcome: Sendable {
        var succeeded: Bool
        var details: [String]
    }

    private struct ResetResult: Sendable {
        var succeeded: Bool
        var detail: String?
    }

    private final class ResetProcessBox: @unchecked Sendable {
        let process = Process()
    }

    /// One-shot completion latch for the `tccutil` run: the first of the
    /// termination handler, the already-exited check, or the timeout
    /// resumes the continuation and cancels the timeout task.
    private final class ResetWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<Int32, Never>?
        private var timeout: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<Int32, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func armTimeout(seconds: Double, onFire: @escaping @Sendable () -> Void) {
            let timeout = Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.fire(status: -1, action: onFire)
            }
            lock.withLock { self.timeout = timeout }
        }

        func fire(status: Int32, action: @escaping @Sendable () -> Void = {}) {
            lock.lock()
            guard !resumed, let continuation else {
                lock.unlock()
                return
            }
            resumed = true
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            lock.unlock()
            action()
            continuation.resume(returning: status)
        }
    }

    nonisolated private static func runReset(service: String, bundleIdentifier: String) async -> ResetResult {
        let box = ResetProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: tccToolPath)
        process.arguments = ["reset", service, bundleIdentifier]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return ResetResult(succeeded: false, detail: String(describing: error).prefix(160).description)
        }
        let status: Int32 = await withCheckedContinuation { continuation in
            let waiter = ResetWaiter()
            waiter.attach(continuation)
            // Install the handler before the early-exit check: Foundation
            // may not invoke one installed after termination began, which
            // would leak the continuation and suspend dictation forever.
            process.terminationHandler = { finished in
                waiter.fire(status: finished.terminationStatus)
            }
            if !process.isRunning {
                waiter.fire(status: process.terminationStatus)
                return
            }
            waiter.armTimeout(seconds: Self.resetTimeoutSeconds) {
                if process.isRunning { process.terminate() }
            }
        }
        guard status != -1 else { return ResetResult(succeeded: false, detail: "timed out") }
        guard status == 0 else {
            let stderr = Self.firstLine(of: errorPipe.fileHandleForReading.availableData)
            let detail = stderr.isEmpty ? "exit \(status)" : "exit \(status): \(stderr)"
            return ResetResult(succeeded: false, detail: detail)
        }
        return ResetResult(succeeded: true, detail: nil)
    }

    nonisolated private static func firstLine(of data: Data) -> String {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let line =
            text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? ""
        return String(line.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct PermissionDiagnostics: Sendable, Equatable {
    public var runsUnbundled: Bool
    public var bundleIdentifier: String?
    public var microphoneUsageDescriptionPresent: Bool
    public var rawRecordPermission: String
    public var microphoneStatus: PermissionsManager.MicrophoneStatus
    public var accessibilityGranted: Bool

    public init(
        runsUnbundled: Bool, bundleIdentifier: String?, microphoneUsageDescriptionPresent: Bool,
        rawRecordPermission: String, microphoneStatus: PermissionsManager.MicrophoneStatus,
        accessibilityGranted: Bool
    ) {
        self.runsUnbundled = runsUnbundled
        self.bundleIdentifier = bundleIdentifier
        self.microphoneUsageDescriptionPresent = microphoneUsageDescriptionPresent
        self.rawRecordPermission = rawRecordPermission
        self.microphoneStatus = microphoneStatus
        self.accessibilityGranted = accessibilityGranted
    }

    /// One readout line per fact, for the on-screen diagnostics list.
    public var lines: [String] {
        [
            "Launch: \(runsUnbundled ? "raw binary (unbundled)" : "app bundle")",
            "Bundle id: \(bundleIdentifier ?? "none")",
            "Microphone description in bundle: \(microphoneUsageDescriptionPresent ? "present" : "missing")",
            "System microphone state: \(rawRecordPermission)",
            "Microphone status: \(microphoneStatus.label)",
            "Accessibility: \(accessibilityGranted ? "granted" : "not granted")",
        ]
    }
}
