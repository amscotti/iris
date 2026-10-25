import IrisCore

extension StartupReadiness.MissingItem {
    public var label: String {
        switch self {
        case .microphone: return "Microphone access"
        case .microphoneBlockedByPolicy: return "Microphone access (blocked by policy)"
        case .accessibility: return "Accessibility access"
        case .apiKey: return "API key"
        case .keyAccess: return "Keychain access"
        case .providerUnavailable: return "Available speech provider"
        }
    }
}
