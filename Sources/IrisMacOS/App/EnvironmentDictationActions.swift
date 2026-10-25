import Foundation
import IrisCore

@MainActor
extension AppEnvironment {
    public var requiresRelaunch: Bool { runtime.requiresRestart }
    public var inputState: InputRuntimeState { runtime.state }
    var settingsRepository: SettingsRepository { settingsController.repository }

    public func readClipboardText() -> String? { clipboard.string() }
    public func readClipboardTextResult() -> ClipboardTextRead { clipboard.readString() }
    @discardableResult public func copyTextToClipboard(_ text: String) -> Bool { clipboard.setString(text) }
    public var canRestartApplication: Bool { AppRelauncher.canRelaunch }
    public func restartApplication() { AppRelauncher.relaunch() }
    public var launchAtLogin: Bool { LoginItem.isEnabled }
    public var launchAtLoginNeedsApproval: Bool { LoginItem.needsApproval }
    public func setLaunchAtLogin(_ enabled: Bool) -> String? { LoginItem.setEnabled(enabled) }

    /// How to start and finish dictation right now, including the active
    /// shortcut mode and provider.
    public var dictationHint: String {
        let hotkey = settings.hotkey
        let key = ShortcutTab.keyOptions.first { $0.keyCode == hotkey.keyCode }?.name ?? "your shortcut"
        if hotkey.mode == .toggle {
            return "Press \(key) to dictate with \(settings.providerName); press again to finish"
        }
        return "Hold \(key) to dictate with \(settings.providerName); release to finish"
    }

    /// Requests cancellation through the runtime without blocking menu UI.
    public func cancelDictation() {
        guard canCancelDictation, let takeID = activeTakeID else { return }
        Task { @MainActor in
            if let cancelDictationForTesting {
                _ = await cancelDictationForTesting(takeID)
            } else {
                _ = await runtime.cancelDictation(takeID: takeID)
            }
        }
    }

    /// Copies only after an explicit user action; the retained transcript is
    /// never written to the clipboard as a side effect of an insertion error.
    @discardableResult
    public func copyLastDictationToClipboard() -> Bool {
        guard let lastDictationText else { return false }
        let copied = copyTextToClipboard(lastDictationText)
        if copied {
            if lastDictationError == NoticePresentation.message(for: .insertion(.clipboardCopyFailed)) {
                clearRetainedNotice()
                applyRestingStatus()
            }
        } else {
            let notice = DictationNotice.insertion(.clipboardCopyFailed)
            retainNotice(
                NoticePresentation.message(for: notice), kind: NoticePresentation.noticeKind(for: notice))
            applyRestingStatus()
        }
        return copied
    }
}
