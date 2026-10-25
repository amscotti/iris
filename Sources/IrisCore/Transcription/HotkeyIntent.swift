import Foundation

/// Pure physical-press intent, scoped by take ID. It issues commands without I/O.
public struct HotkeyIntent: Sendable, Equatable {
    public enum Press: Sendable, Equatable {
        case none, refused
        case started(Int)
        case toggleStop(Int)
    }
    public enum Command: Sendable, Equatable {
        case none, begin, busy
        case end(Int)
        case cancel(Int)
    }
    public struct ActiveTake: Sendable, Equatable {
        public let id: Int
        public let phase: TakeLifecycle.Phase
        public let isSilentQuickTake: Bool
        public init(id: Int, phase: TakeLifecycle.Phase, isSilentQuickTake: Bool) {
            self.id = id
            self.phase = phase
            self.isSilentQuickTake = isSilentQuickTake
        }
    }
    public private(set) var press: Press = .none
    public private(set) var toggleTakeID: Int?
    public init() {}

    public mutating func reduce(_ event: HotkeyEvent, mode: HotkeyConfiguration.Mode, active: ActiveTake?) -> Command {
        switch event {
        case .pressed: return pressed(mode: mode, active: active)
        case .released: return released(mode: mode, active: active)
        case .cancelled: return chord(mode: mode, active: active)
        }
    }

    public mutating func acceptedTake(id: Int, mode: HotkeyConfiguration.Mode) {
        press = .started(id)
        toggleTakeID = mode == .toggle ? id : nil
    }
    public mutating func refusedTake() {
        press = .refused
        toggleTakeID = nil
    }

    private mutating func pressed(mode: HotkeyConfiguration.Mode, active: ActiveTake?) -> Command {
        if mode == .toggle, let active, active.id == toggleTakeID {
            switch active.phase {
            case .starting:
                refusedTake()
                return .cancel(active.id)
            case .recording:
                press = .toggleStop(active.id)
                return .none
            case .finalizing: break
            }
        }
        if active != nil {
            refusedTake()
            return .busy
        }
        return .begin
    }

    private mutating func released(mode: HotkeyConfiguration.Mode, active: ActiveTake?) -> Command {
        let prior = press
        press = .none
        switch prior {
        case .started(let id) where mode == .hold:
            return active?.id == id ? .end(id) : .none
        case .toggleStop(let id):
            if toggleTakeID == id { toggleTakeID = nil }
            return active?.id == id ? .end(id) : .none
        default: return .none
        }
    }

    private mutating func chord(mode: HotkeyConfiguration.Mode, active: ActiveTake?) -> Command {
        let prior = press
        press = .none
        guard case .started(let id) = prior, let active, active.id == id, active.phase != .finalizing
        else { return .none }
        if mode == .toggle, active.phase == .recording, !active.isSilentQuickTake { return .none }
        if toggleTakeID == id { toggleTakeID = nil }
        return .cancel(id)
    }
}
