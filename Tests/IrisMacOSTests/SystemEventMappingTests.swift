import AppKit
import Testing

@testable import IrisMacOS

@Test @MainActor func displaySleepAndWakeHaveIndependentSuspensionEvents() {
    #expect(SystemEvents.workspaceEvent(for: NSWorkspace.screensDidSleepNotification) == .displaySleep)
    #expect(SystemEvents.workspaceEvent(for: NSWorkspace.screensDidWakeNotification) == .displayWake)
    #expect(SystemEvents.workspaceEvent(for: NSWorkspace.willSleepNotification) == .sleep)
    #expect(SystemEvents.workspaceEvent(for: NSWorkspace.didWakeNotification) == .wake)
}

@Test @MainActor func screenLockAndUnlockHaveIndependentSuspensionEvents() {
    #expect(SystemEvents.distributedEvent(for: SystemEvents.screenLockedNotification) == .screenLocked)
    #expect(SystemEvents.distributedEvent(for: SystemEvents.screenUnlockedNotification) == .screenUnlocked)
    #expect(SystemEvents.workspaceEvent(for: NSWorkspace.sessionDidResignActiveNotification) == .sessionInactive)
    #expect(SystemEvents.workspaceEvent(for: NSWorkspace.sessionDidBecomeActiveNotification) == .sessionActive)
}

@Test @MainActor func lockStateIsSeededFromTheSessionDictionary() {
    #expect(SystemEvents.isScreenLocked(["CGSSessionScreenIsLocked": true]))
    #expect(!SystemEvents.isScreenLocked(["CGSSessionScreenIsLocked": false]))
    #expect(!SystemEvents.isScreenLocked(nil))
    #expect(SystemEvents.screenLockEvent(isLocked: true) == .screenLocked)
    #expect(SystemEvents.screenLockEvent(isLocked: false) == .screenUnlocked)
}

@Test @MainActor func ordinaryApplicationDeactivationIsNotMappedToScreenLock() {
    #expect(SystemEvents.distributedEvent(for: NSApplication.didResignActiveNotification) == nil)
    #expect(SystemEvents.workspaceEvent(for: NSApplication.didResignActiveNotification) == nil)
}
