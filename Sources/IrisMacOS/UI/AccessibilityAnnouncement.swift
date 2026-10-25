import AppKit

/// Shared VoiceOver announcement boundary for status changes that occur
/// outside the focused control or in a panel that never takes focus.
@MainActor
enum AccessibilityAnnouncement {
    static func post(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}
