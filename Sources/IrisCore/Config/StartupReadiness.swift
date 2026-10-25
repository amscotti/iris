import Foundation

/// Launch-readiness computation for the startup gate.
///
/// Pure value logic with no system calls, so it stays unit-testable: the
/// caller supplies the three blocking inputs (microphone grant,
/// Accessibility trust, API key presence) and reads back whether dictation
/// can run plus which items still block it. A locked Keychain is not a
/// missing key: the stored secret may already be there.
public struct StartupReadiness: Sendable, Equatable, Hashable {
    /// One blocking requirement, in the order the UI presents them.
    public enum MissingItem: String, Sendable, Equatable, Hashable, CaseIterable {
        case microphone
        /// The microphone is restricted by device policy; unlike a plain
        /// missing grant, System Settings cannot re-enable it.
        case microphoneBlockedByPolicy
        case accessibility
        case apiKey
        case keyAccess
        case providerUnavailable
    }

    public var microphoneGranted: Bool
    public var accessibilityGranted: Bool
    public var apiKeyPresent: Bool
    /// Keychain could not be read. Mutually exclusive with a missing-key item.
    public var keyAccessUnavailable: Bool
    /// True when the microphone is restricted by policy (which also implies
    /// `microphoneGranted == false`), so the blocker can be presented as
    /// unfixable from System Settings.
    public var microphoneRestricted: Bool
    /// The persisted route names a provider registered in this build.
    public var providerAvailable: Bool

    public init(
        microphoneGranted: Bool, accessibilityGranted: Bool, apiKeyPresent: Bool,
        keyAccessUnavailable: Bool = false, microphoneRestricted: Bool = false,
        providerAvailable: Bool = true
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
        self.apiKeyPresent = apiKeyPresent
        self.keyAccessUnavailable = keyAccessUnavailable
        self.microphoneRestricted = microphoneRestricted
        self.providerAvailable = providerAvailable
    }

    /// True only when dictation can run: both system grants, a readable
    /// Keychain, and a key when the provider requires one.
    public var isReady: Bool {
        microphoneGranted && accessibilityGranted && apiKeyPresent && !keyAccessUnavailable && providerAvailable
    }

    /// Blocking items in presentation order. Empty when ready.
    public var missingItems: [MissingItem] {
        var missing: [MissingItem] = []
        if !microphoneGranted {
            missing.append(microphoneRestricted ? .microphoneBlockedByPolicy : .microphone)
        }
        if !accessibilityGranted {
            missing.append(.accessibility)
        }
        if !providerAvailable {
            missing.append(.providerUnavailable)
        } else if keyAccessUnavailable {
            missing.append(.keyAccess)
        } else if !apiKeyPresent {
            missing.append(.apiKey)
        }
        return missing
    }

    public static func evaluate(
        microphoneGranted: Bool, accessibilityGranted: Bool, apiKeyPresent: Bool,
        keyAccessUnavailable: Bool = false, microphoneRestricted: Bool = false,
        providerAvailable: Bool = true
    ) -> StartupReadiness {
        StartupReadiness(
            microphoneGranted: microphoneGranted, accessibilityGranted: accessibilityGranted,
            apiKeyPresent: apiKeyPresent, keyAccessUnavailable: keyAccessUnavailable,
            microphoneRestricted: microphoneRestricted, providerAvailable: providerAvailable)
    }
}
