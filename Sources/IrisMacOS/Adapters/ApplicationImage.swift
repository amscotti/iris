import Foundation
import Security
import os

/// Platform code-signature validation before capture. A rebuilt bundle can invalidate
/// privacy grants while an older process still has cached authorization.
/// This is a code-signature check, not a Keychain read, and never prompts.
enum ApplicationImage {
    static let changedMessage = "Iris was updated while running. Quit and reopen Iris before dictating."

    /// True when the running image verifies. A `SecCodeCopySelf` API failure
    /// is "check failed", not "signature invalid": it fails open (with a log)
    /// and is re-checked on the next press, so a transient OS error never
    /// latches relaunch-required state. Only a confirmed validity failure
    /// returns false.
    static func isCurrent() -> Bool {
        let log = Logger(subsystem: AppIdentity.identifier, category: "dictation")
        var code: SecCode?
        let flags = SecCSFlags(rawValue: 0)
        let copyStatus = SecCodeCopySelf(flags, &code)
        guard copyStatus == errSecSuccess, let code else {
            log.error(
                "Code signature self-check unavailable (status \(copyStatus, privacy: .public)); allowing this press and rechecking next time."
            )
            return true
        }
        let validity = SecCodeCheckValidity(code, flags, nil)
        guard validity == errSecSuccess else {
            log.notice(
                "Running app code signature no longer validates (status \(validity, privacy: .public)).")
            return false
        }
        return true
    }
}
