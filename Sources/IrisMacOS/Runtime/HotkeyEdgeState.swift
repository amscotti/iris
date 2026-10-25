import AppKit
import IrisCore

struct HotkeyInput: Sendable {
    enum Kind: Sendable, Equatable { case keyDown, keyUp, flagsChanged }
    var kind: Kind
    var keyCode: Int
    var modifiers: UInt = 0
    var isRepeat = false

    init(kind: Kind, keyCode: Int, modifiers: UInt = 0, isRepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    init?(event: NSEvent) {
        switch event.type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return nil
        }
        keyCode = Int(event.keyCode)
        modifiers = event.modifierFlags.rawValue
        isRepeat = event.type == .keyDown && event.isARepeat
    }
}

/// Edge classification. It reads only the event payload plus an injected
/// physical-key probe (inert by default); no WindowServer calls, event-tap
/// operations, permissions, or recording work happen here.
struct HotkeyEdgeState {
    private(set) var keyCode: Int
    private(set) var isDown = false
    private(set) var awaitingRelease = false
    /// The current press was turned into a typing chord and already cancelled.
    private(set) var chorded = false
    /// Non-hotkey keys currently down (autorepeats excluded), so a press that
    /// begins mid-chord is cancelled immediately instead of when the held
    /// key next repeats.
    private var otherKeysDown: Set<Int> = []
    /// Reports whether a physical key is down. The owner injects the real
    /// keyboard state so edges lost to a dropout or secure input can be
    /// reconciled; the default trusts the tracked edges alone.
    private let physicalKeyDown: (Int) -> Bool

    private static let modifierMasks: [Int: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 60: .shift, 57: .capsLock,
        58: .option, 61: .option, 59: .control, 62: .control, 63: .function,
    ]

    init(keyCode: Int, physicalKeyDown: @escaping (Int) -> Bool = { _ in true }) {
        self.keyCode = keyCode
        self.physicalKeyDown = physicalKeyDown
    }

    mutating func reset(requireRelease: Bool = false) {
        isDown = false
        chorded = false
        otherKeysDown.removeAll()
        awaitingRelease = requireRelease
    }

    mutating func retarget(_ keyCode: Int, requireRelease: Bool = false) -> HotkeyEvent? {
        guard self.keyCode != keyCode else { return nil }
        let release: HotkeyEvent? = isDown && !chorded ? .released : nil
        self.keyCode = keyCode
        reset(requireRelease: requireRelease)
        return release
    }

    /// Reconciles tracked edges when no further input event arrives. A
    /// chorded hold still ends silently, exactly as it does for a real key-up.
    mutating func reconcile() -> HotkeyEvent? {
        guard isDown || awaitingRelease, !physicalKeyDown(keyCode) else { return nil }
        if awaitingRelease { awaitingRelease = false }
        guard isDown else { return nil }
        return release()
    }

    mutating func handle(_ input: HotkeyInput) -> HotkeyEvent? {
        if awaitingRelease, !physicalKeyDown(keyCode) {
            // The awaited release never came (dropout, secure input) and the
            // key is physically up: clear the wait now, or the next matching
            // event is consumed as the release and a whole press is eaten.
            awaitingRelease = false
        }
        if isDown, !physicalKeyDown(keyCode), !isChordWithHeldModifier(input) {
            // The held key's up was lost (dropout, secure input): reconcile
            // on the next observed event instead of holding the press open.
            return release()
        }
        guard input.keyCode == self.keyCode else { return handleOtherKey(input) }
        let flags = NSEvent.ModifierFlags(rawValue: input.modifiers)
        let mask = Self.modifierMasks[input.keyCode]
        if awaitingRelease {
            // Waiting for the key held across a restart to come up. Only
            // this key's own change counts: the shared mask stays held when
            // the opposite side of the modifier is down, and an unrelated
            // modifier's flagsChanged must not clear the wait.
            let released = input.kind == .keyUp || (input.kind == .flagsChanged && input.keyCode == self.keyCode)
            if released { awaitingRelease = false }
            return nil
        }
        if let mask, input.kind == .flagsChanged {
            let held = flags.contains(mask)
            if isDown {
                // A matching flags event while already down is this side's
                // release, even if the other side still holds the shared mask.
                return release()
            }
            guard held else { return nil }
            return beginPress()
        }
        if input.kind == .keyDown, !input.isRepeat, !isDown {
            return beginPress()
        }
        if input.kind == .keyUp, isDown {
            return release()
        }
        return nil
    }

    /// Tracks non-hotkey keys and cancels the hold when one goes down: the
    /// person is typing a chord with the hotkey, not dictating. Autorepeats
    /// are not chord evidence of their own.
    private mutating func handleOtherKey(_ input: HotkeyInput) -> HotkeyEvent? {
        switch input.kind {
        case .keyDown: otherKeysDown.insert(input.keyCode)
        case .keyUp: otherKeysDown.remove(input.keyCode)
        case .flagsChanged: break
        }
        guard isDown, !chorded, input.kind == .keyDown, !input.isRepeat else { return nil }
        chorded = true
        return .cancelled
    }

    /// Starts a fresh press. A chord already in progress turns it into a
    /// silent cancellation instead. Entries whose physical key is
    /// demonstrably up lost their key-up and are pruned first.
    private mutating func beginPress() -> HotkeyEvent {
        isDown = true
        if !otherKeysDown.isEmpty {
            otherKeysDown = otherKeysDown.filter(physicalKeyDown)
            if !otherKeysDown.isEmpty {
                chorded = true
                return .cancelled
            }
        }
        chorded = false
        return .pressed
    }

    /// A cancelled (chorded) press already ended, so its release is silent.
    private mutating func release() -> HotkeyEvent? {
        isDown = false
        return chorded ? nil : .released
    }

    private func isChordWithHeldModifier(_ input: HotkeyInput) -> Bool {
        guard input.keyCode != keyCode, input.kind == .keyDown, !input.isRepeat,
            let mask = Self.modifierMasks[keyCode]
        else { return false }
        return NSEvent.ModifierFlags(rawValue: input.modifiers).contains(mask)
    }
}
