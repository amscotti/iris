import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

extension AccessControlTextInserter {
    /// Whether system-wide secure input should refuse keystrokes: only when
    /// the focused app holds it, or when either process is unknown.
    nonisolated static func secureInputBlocksInsertion(holderPID: pid_t?, focusedPID: pid_t?) -> Bool {
        guard let holderPID, let focusedPID else { return true }
        return holderPID == focusedPID
    }

    /// Pure decision behind `focusedFieldIsSecure()`, factored so the policy
    /// can be unit-tested without a live AX tree.
    nonisolated static func secureDisposition(
        subrole: String?, role: String?, secureInputEnabled: Bool
    ) -> Bool {
        if secureInputEnabled { return true }
        if subrole == secureFieldType { return true }
        return role == secureFieldType
    }

    /// Best-effort secure-field check on the focused element. Unknown or
    /// unreadable focus is treated as insertable; only a positive secure
    /// subrole/role — or system-wide secure input — refuses keystrokes.
    nonisolated static func focusedFieldIsSecure() -> Bool {
        let systemWide = Self.boundedTimeout(AXUIElementCreateSystemWide())
        var focusedApp: AnyObject?
        var app: AXUIElement?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
            == .success, let rawApp = focusedApp, CFGetTypeID(rawApp) == AXUIElementGetTypeID()
        {
            app = unsafeDowncast(rawApp, to: AXUIElement.self)
        }
        // Secure Event Input (password sheets, Terminal's "Secure Keyboard
        // Entry") is system-wide, so a background app that never releases it
        // would block dictation everywhere. Refuse when the app receiving the
        // keystrokes holds it, or when either side cannot be identified.
        var secureInput = false
        if IsSecureEventInputEnabled() {
            var pid: pid_t = 0
            let focusedPID = app.flatMap { AXUIElementGetPid($0, &pid) == .success ? pid : nil }
            secureInput = secureInputBlocksInsertion(
                holderPID: secureInputHolderPID(), focusedPID: focusedPID)
        }
        var subroleString: String?
        var roleString: String?
        if let app {
            var focusedElement: AnyObject?
            if AXUIElementCopyAttributeValue(
                app, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
                let rawElement = focusedElement,
                CFGetTypeID(rawElement) == AXUIElementGetTypeID()
            {
                let element = unsafeDowncast(rawElement, to: AXUIElement.self)
                var subrole: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                    == .success, let value = subrole as? String
                {
                    subroleString = value
                }
                var role: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                    let value = role as? String
                {
                    roleString = value
                }
            }
        }
        return secureDisposition(
            subrole: subroleString, role: roleString, secureInputEnabled: secureInput)
    }

    /// AX messaging defaults to a ~6 s timeout per call; an unresponsive
    /// frontmost app must not stall the insert path. Applying the timeout to
    /// the system-wide element sets it process-wide (per the AX SDK header),
    /// so the subsequent app/element probes inherit the bound.
    nonisolated static func boundedTimeout(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 1.0)
        return element
    }

    /// The process holding Secure Event Input. The session dictionary key is
    /// not formally documented but has been stable for many macOS releases;
    /// nil (unknown) keeps the conservative refusal.
    nonisolated static func secureInputHolderPID() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }
}
