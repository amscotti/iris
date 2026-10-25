import Testing

@testable import IrisCore

@Test func holdIntentEndsOnlyItsAcceptedTake() {
    var input = HotkeyIntent()
    #expect(input.reduce(.pressed, mode: .hold, active: nil) == .begin)
    input.acceptedTake(id: 1, mode: .hold)
    let active = HotkeyIntent.ActiveTake(id: 1, phase: .recording, isSilentQuickTake: false)
    #expect(input.reduce(.released, mode: .hold, active: active) == .end(1))
    #expect(input.reduce(.released, mode: .hold, active: active) == .none)
    #expect(input.press == .none)
}

@Test(arguments: [TakeLifecycle.Phase.starting, .recording, .finalizing])
func busyIntentNeverReplaysAPressAfterTheTakeCompletes(phase: TakeLifecycle.Phase) {
    var input = HotkeyIntent()
    let active = HotkeyIntent.ActiveTake(id: 1, phase: phase, isSilentQuickTake: false)
    #expect(input.reduce(.pressed, mode: .hold, active: active) == .busy)
    #expect(input.press == .refused)
    #expect(input.reduce(.cancelled, mode: .hold, active: active) == .none)
    #expect(input.reduce(.released, mode: .hold, active: nil) == .none)
    #expect(input.reduce(.pressed, mode: .hold, active: nil) == .begin)
}

@Test(arguments: [HotkeyEvent.released, .cancelled])
func stalePhysicalEdgesCannotEndOrCancelANewerTake(event: HotkeyEvent) {
    var input = HotkeyIntent()
    input.acceptedTake(id: 1, mode: .hold)
    let newer = HotkeyIntent.ActiveTake(id: 2, phase: .recording, isSilentQuickTake: true)
    #expect(input.reduce(event, mode: .hold, active: newer) == .none)
    #expect(input.press == .none)
}

@Test func toggleIntentStopsOnAnUnchordedRelease() {
    var input = HotkeyIntent()
    input.acceptedTake(id: 1, mode: .toggle)
    let active = HotkeyIntent.ActiveTake(id: 1, phase: .recording, isSilentQuickTake: false)
    #expect(input.reduce(.released, mode: .toggle, active: active) == .none)
    #expect(input.reduce(.pressed, mode: .toggle, active: active) == .none)
    #expect(input.press == .toggleStop(1))
    #expect(input.reduce(.cancelled, mode: .toggle, active: active) == .none)
    #expect(input.toggleTakeID == 1)
    #expect(input.reduce(.released, mode: .toggle, active: active) == .none)
    #expect(input.reduce(.pressed, mode: .toggle, active: active) == .none)
    #expect(input.reduce(.released, mode: .toggle, active: active) == .end(1))
    #expect(input.toggleTakeID == nil)
}

@Test func establishedToggleSurvivesAChordOnItsStartingPhysicalPress() {
    var input = HotkeyIntent()
    input.acceptedTake(id: 1, mode: .toggle)
    let active = HotkeyIntent.ActiveTake(id: 1, phase: .recording, isSilentQuickTake: false)
    #expect(input.reduce(.cancelled, mode: .toggle, active: active) == .none)
    #expect(input.toggleTakeID == 1)
    #expect(input.reduce(.pressed, mode: .toggle, active: active) == .none)
    #expect(input.reduce(.released, mode: .toggle, active: active) == .end(1))
}

@Test(arguments: [TakeLifecycle.Phase.starting, .recording])
func accidentalToggleChordsCancelOnlyTheAcceptedTake(phase: TakeLifecycle.Phase) {
    var input = HotkeyIntent()
    input.acceptedTake(id: 1, mode: .toggle)
    let active = HotkeyIntent.ActiveTake(id: 1, phase: phase, isSilentQuickTake: true)
    #expect(input.reduce(.cancelled, mode: .toggle, active: active) == .cancel(1))
    #expect(input.toggleTakeID == nil)
    #expect(input.reduce(.released, mode: .toggle, active: nil) == .none)
}

@Test func secondTogglePressCancelsStartupInsteadOfWaitingForAnACK() {
    var input = HotkeyIntent()
    input.acceptedTake(id: 1, mode: .toggle)
    let active = HotkeyIntent.ActiveTake(id: 1, phase: .starting, isSilentQuickTake: false)
    #expect(input.reduce(.released, mode: .toggle, active: active) == .none)
    #expect(input.reduce(.pressed, mode: .toggle, active: active) == .cancel(1))
    #expect(input.press == .refused)
    #expect(input.toggleTakeID == nil)
    #expect(input.reduce(.released, mode: .toggle, active: nil) == .none)
}

@Test func cleanupRefusalDoesNotRetainAStopOrCancelIntent() {
    var input = HotkeyIntent()
    #expect(input.reduce(.pressed, mode: .toggle, active: nil) == .begin)
    input.refusedTake()
    let newer = HotkeyIntent.ActiveTake(id: 2, phase: .recording, isSilentQuickTake: false)
    #expect(input.reduce(.released, mode: .toggle, active: newer) == .none)
    #expect(input.reduce(.cancelled, mode: .toggle, active: newer) == .none)
}
