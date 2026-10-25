import Foundation

/// The platform's reverse-DNS identity, shared by the log subsystem and the
/// Keychain service. `Scripts/build_app.sh` writes the same value as the
/// bundle identifier, which also names the preferences domain.
public enum AppIdentity {
    public static let identifier = "io.github.amscotti.iris"
}
