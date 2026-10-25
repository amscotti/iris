import Foundation

/// Edge transitions of the push-to-talk hotkey.
public enum HotkeyEvent: Sendable, Equatable, Hashable {
    case pressed
    case released
    /// Another key went down while the hotkey was held: the press is typing
    /// (⌥-arrows, accents, AltGr characters), not dictation. Discard it
    /// silently. No `.released` follows for a cancelled press.
    case cancelled
}

/// Platform-independent hotkey description.
public struct HotkeyConfiguration: Sendable, Equatable, Hashable, Codable {
    public enum Mode: String, Sendable, Equatable, Hashable, Codable {
        case hold
        case toggle
    }

    /// The shipped default: hold Right-Option. Single source of truth for
    /// the domain default, the monitor, and the Settings picker row.
    public static let defaultKeyCode = 61

    /// Hardware key code (default: hold Right-Option).
    public var keyCode: Int
    /// Modifier bitmask in the host's convention.
    public var modifiers: Int
    public var mode: Mode

    public init(keyCode: Int = HotkeyConfiguration.defaultKeyCode, modifiers: Int = 0, mode: Mode = .hold) {
        precondition(keyCode >= 0, "Hotkey keyCode must be non-negative.")
        precondition(modifiers >= 0, "Hotkey modifiers must be non-negative.")
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case mode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decodeIfPresent(Int.self, forKey: .keyCode) ?? HotkeyConfiguration.defaultKeyCode
        modifiers = try container.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0
        // Invalid values fall back per-field: a corrupted key code must not
        // discard the stored mode too (the whole-struct `try?` upstream
        // would otherwise silently reset the entire hotkey).
        if keyCode < 0 { keyCode = HotkeyConfiguration.defaultKeyCode }
        if modifiers < 0 { modifiers = 0 }
        // Unknown future mode strings fall back to hold so one new value
        // cannot discard the entire settings payload. A genuine type
        // mismatch still throws, like keyCode/modifiers above.
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
        mode = rawMode.flatMap { Mode(rawValue: $0) } ?? .hold
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(mode, forKey: .mode)
    }
}
