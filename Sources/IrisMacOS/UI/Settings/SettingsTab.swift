import Foundation

/// Settings tabs, stored on the environment so the app can deep-link
/// straight to one.
///
/// Case names match the pane titles; raw values are the persisted pane IDs
/// and stay unchanged so a saved "last pane" keeps restoring.
public enum SettingsTab: String, Sendable, Equatable, Hashable, CaseIterable {
    case providers = "dictation"
    case shortcut = "hotkey"
    case prompts
    case typing = "advanced"
    case appearance = "general"
    case permissions

    static let storageKey = "iris.settingsPane"

    public var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .providers: return "Providers"
        case .shortcut: return "Shortcut"
        case .permissions: return "Permissions"
        case .prompts: return "Prompts"
        case .typing: return "Typing"
        }
    }

    public var symbol: String {
        switch self {
        case .appearance: return "waveform"
        case .providers: return "network"
        case .shortcut: return "keyboard"
        case .permissions: return "lock.shield"
        case .prompts: return "sparkles"
        case .typing: return "character.cursor.ibeam"
        }
    }
}
