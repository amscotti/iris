import AppKit
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test func ordinaryKeyDownAndUpEmitEdges() {
    var state = HotkeyEdgeState(keyCode: 0)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == .released)
}

@Test func autoRepeatAndStrayReleasesEmitNothing() {
    var state = HotkeyEdgeState(keyCode: 0)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == nil)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0, isRepeat: true)) == nil)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == nil)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == .released)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == nil)
}

@Test func otherKeyCodesDoNotAffectACompletedChord() {
    var state = HotkeyEdgeState(keyCode: 0)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 1)) == nil)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 1)) == nil)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == .released)
}

@Test func modifierFlagMovesEmitEdges() {
    var state = HotkeyEdgeState(keyCode: 61)
    #expect(
        state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue))
            == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == .released)
}

@Test func modifierReleaseWorksWhileTheOtherSideHoldsTheMask() {
    var state = HotkeyEdgeState(keyCode: 61)
    let event = HotkeyInput(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue)
    #expect(state.handle(event) == .pressed)
    #expect(state.handle(event) == .released)
}

@Test func retargetingResetsInFlightState() {
    var state = HotkeyEdgeState(keyCode: 0)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.retarget(1) == .released)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == nil)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 1)) == .pressed)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 1)) == .released)
}

@Test func sameKeyCodeUpdateDoesNotDropAHold() {
    var state = HotkeyEdgeState(keyCode: 0)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.retarget(0) == nil)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == .released)
}

@Test func heldKeyAfterRecoveryMustBeReleasedBeforeANewPress() {
    var state = HotkeyEdgeState(keyCode: 61)
    state.reset(requireRelease: true)
    #expect(
        state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == nil)
    #expect(
        state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue))
            == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == .released)
}

@Test func duplicateModifierUpDoesNotPress() {
    var state = HotkeyEdgeState(keyCode: 61)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == nil)
    #expect(
        state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue))
            == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == .released)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == nil)
}

@Test @MainActor func localObservationAlwaysReturnsTheOriginalEvent() throws {
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    var observed = false
    let returned = HotkeyEventForwarding.passThrough(event) { input in observed = input.keyCode == 0 }
    #expect(returned === event)
    #expect(observed)
}

/// Lock-boxed edge recorder for streaming consumers.
final class EdgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HotkeyEvent] = []
    func append(_ edge: HotkeyEvent) {
        lock.lock()
        stored.append(edge)
        lock.unlock()
    }
    var edges: [HotkeyEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Test @MainActor func stoppedObserverCallbacksCannotEnterTheNextGeneration() async throws {
    let backend = TestHotkeyEvents()
    let monitor = GlobalHotkeyMonitor(keyCode: 0, backend: backend)
    #expect(monitor.start())
    let old = try #require(backend.globalHandlers.last)
    monitor.stop()
    #expect(monitor.start())
    let stream = monitor.events()
    let recorder = EdgeRecorder()
    let consumer = Task { @MainActor in
        for await edge in stream { recorder.append(edge) }
    }
    // Stale-generation edges must produce nothing. A continuous consumer
    // cannot hide a missing generation guard behind latest-edge
    // coalescing, unlike consuming only after the live edges are fired.
    old(.init(kind: .keyDown, keyCode: 0))
    old(.init(kind: .keyUp, keyCode: 0))
    #expect(backend.physicalReads == 2)  // Setup only, never a callback query.
    try? await Task.sleep(nanoseconds: 150_000_000)
    #expect(recorder.edges.isEmpty)
    // The live observers still drive a normal pair after the stale attempt.
    backend.globalHandlers.last?(.init(kind: .keyDown, keyCode: 0))
    backend.localHandlers.last?(.init(kind: .keyUp, keyCode: 0))
    let deadline = Date().addingTimeInterval(10)
    while recorder.edges.count < 2, Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    monitor.stop()
    _ = await consumer.value
    #expect(recorder.edges == [.pressed, .released])
    #expect(backend.activeTokens.isEmpty)
}

@Test @MainActor func observerInstallFailureRemovesPartialRegistration() {
    let backend = TestHotkeyEvents()
    backend.failGlobal = true
    let monitor = GlobalHotkeyMonitor(backend: backend)
    #expect(!monitor.start())
    #expect(!monitor.isMonitoring)
    #expect(backend.activeTokens.isEmpty)
}

@Test func typingChordCancelsThePressAndSilencesItsRelease() {
    var optionPhysicallyDown = true
    var state = HotkeyEdgeState(keyCode: 61, physicalKeyDown: { $0 == 61 ? optionPhysicallyDown : true })
    let option = NSEvent.ModifierFlags.option.rawValue
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    // Right Option + L types "@" on many layouts: typing, not dictation.
    // Even if the user already released Right Option physically before the
    // async global monitor callback ran, the event's own modifier snapshot
    // proves the chord and must cancel rather than release.
    optionPhysicallyDown = false
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37, modifiers: option)) == .cancelled)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37, modifiers: option, isRepeat: true)) == nil)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 37, modifiers: option)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == nil)
    // The next hold on its own dictates again.
    optionPhysicallyDown = true
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == .released)
}

@Test func keyHeldBeforeTheHotkeyCancelsAtPressTime() {
    var state = HotkeyEdgeState(keyCode: 61)
    let option = NSEvent.ModifierFlags.option.rawValue
    // L is already down when Right Option goes down: the chord must be
    // recognized immediately, not whenever L happens to repeat next.
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .cancelled)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == nil)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 37)) == nil)
    // With nothing else down, the next hold is dictation again.
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == .released)
}

@Test func staleOtherKeyEntryIsPrunedWhenItsPhysicalKeyReadsUp() {
    var state = HotkeyEdgeState(keyCode: 61, physicalKeyDown: { _ in false })
    let option = NSEvent.ModifierFlags.option.rawValue
    // L's key-up was lost (Bluetooth dropout); the stale entry must not
    // poison every later press into a silent chord cancellation.
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == .released)
}

@Test func heldOtherKeyConfirmedByPhysicalStateStillCancels() {
    var state = HotkeyEdgeState(keyCode: 61, physicalKeyDown: { $0 == 37 })
    let option = NSEvent.ModifierFlags.option.rawValue
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .cancelled)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == nil)
    // Once the held key really comes up, the next hold dictates again.
    #expect(state.handle(.init(kind: .keyUp, keyCode: 37)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == .released)
}

@Test func lostHotkeyReleaseIsReconciledByTheNextEvent() {
    var physicallyDown = true
    var state = HotkeyEdgeState(keyCode: 0, physicalKeyDown: { _ in physicallyDown })
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    // The hotkey's key-up was lost; any later event synthesizes it so the
    // take ends instead of recording unboundedly.
    physicallyDown = false
    #expect(state.handle(.init(kind: .keyDown, keyCode: 9)) == .released)
    physicallyDown = true
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.handle(.init(kind: .keyUp, keyCode: 0)) == .released)
}

@Test func lostReleaseWhileAwaitingRecoveryLetsTheNextPressThrough() {
    var hotkeyPhysicallyDown = false
    var state = HotkeyEdgeState(keyCode: 61, physicalKeyDown: { $0 == 61 ? hotkeyPhysicallyDown : false })
    state.reset(requireRelease: true)
    // The key held across the restart came up while no matching events were
    // observed (lost release). The next unrelated event must clear the wait
    // via the probe; otherwise the hotkey's own next press is consumed as
    // the awaited release and a whole take is eaten.
    #expect(state.handle(.init(kind: .keyDown, keyCode: 9)) == nil)
    hotkeyPhysicallyDown = true
    let option = NSEvent.ModifierFlags.option.rawValue
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == .released)
}

@Test func physicallyHeldKeyStillSatisfiesTheRecoveryWait() {
    var physicallyDown = true
    var state = HotkeyEdgeState(keyCode: 61, physicalKeyDown: { _ in physicallyDown })
    state.reset(requireRelease: true)
    let option = NSEvent.ModifierFlags.option.rawValue
    // The key really is still down: the wait consumes its held flags event,
    // and only the release ends it — the probe must not clear the wait early.
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == nil)
    physicallyDown = false
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == nil)
    physicallyDown = true
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == .released)
}

@Test func reconciledChordedPressEndsSilently() {
    var physicallyDown = true
    var state = HotkeyEdgeState(keyCode: 0, physicalKeyDown: { _ in physicallyDown })
    #expect(state.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 9)) == .cancelled)
    physicallyDown = false
    // The chorded press already cancelled; its synthesized end stays silent
    // but still clears the held state so the next press can start a take.
    #expect(state.handle(.init(kind: .keyDown, keyCode: 10)) == nil)
    #expect(state.isDown == false)
}

@Test func anotherKeysRepeatIsNotChordEvidence() {
    var state = HotkeyEdgeState(keyCode: 61)
    let option = NSEvent.ModifierFlags.option.rawValue
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: option)) == .pressed)
    // A repeat alone (the original keyDown was never observed) does not
    // cancel a valid hold.
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37, isRepeat: true)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0)) == .released)
}

@Test func otherKeysNeverCancelWhenTheHotkeyIsUp() {
    var state = HotkeyEdgeState(keyCode: 61)
    #expect(state.handle(.init(kind: .keyDown, keyCode: 37)) == nil)
    var plain = HotkeyEdgeState(keyCode: 0)
    #expect(plain.handle(.init(kind: .keyDown, keyCode: 0)) == .pressed)
    #expect(plain.handle(.init(kind: .keyDown, keyCode: 1)) == .cancelled)
    #expect(plain.handle(.init(kind: .keyUp, keyCode: 0)) == nil)
}

@Test func siblingModifierReleaseDoesNotClearAPendingRecoveryRelease() {
    var state = HotkeyEdgeState(keyCode: 61)
    state.reset(requireRelease: true)
    // Right Option is held across the restart. Releasing the LEFT side (58)
    // or an unrelated modifier (Shift, 56) must not satisfy the wait...
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 58)) == nil)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 56)) == nil)
    // ...and a flags event that reports the shared option mask absent for
    // some other key must not either.
    #expect(
        state.handle(.init(kind: .flagsChanged, keyCode: 58, modifiers: NSEvent.ModifierFlags.option.rawValue))
            == nil)
    // Only the held key's own release ends the wait.
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == nil)
    #expect(
        state.handle(.init(kind: .flagsChanged, keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue))
            == .pressed)
    #expect(state.handle(.init(kind: .flagsChanged, keyCode: 61)) == .released)
}

@Test @MainActor func hotkeyEdgesAreNotCoalescedWhileUnread() async {
    // A press+release that lands while the consumer is busy must both
    // survive: latest-edge buffering dropped the pair and the next
    // dictation silently never started.
    let backend = TestHotkeyEvents()
    let monitor = GlobalHotkeyMonitor(keyCode: 61, backend: backend)
    #expect(monitor.start())
    let option = NSEvent.ModifierFlags.option.rawValue
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61, modifiers: option))
    backend.globalHandlers.first?(.init(kind: .flagsChanged, keyCode: 61, modifiers: 0))
    var iterator = monitor.events().makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    #expect(first == .pressed)
    #expect(second == .released)
    monitor.stop()
}
