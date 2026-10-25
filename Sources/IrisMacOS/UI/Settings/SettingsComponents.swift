import IrisCore
import SwiftUI

@MainActor
extension AppEnvironment {
    func binding<Value>(for keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in
                var updated = self.settings
                updated[keyPath: keyPath] = value
                self.saveSettings(updated)
            })
    }
}

/// Quiet, native settings chrome. The rounded title echoes Iris's capsule;
/// controls retain system typography, colors, focus rings, and contrast.
struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeading(title: title, subtitle: subtitle)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The pane fills whatever height remains after any recovery banner;
        // a fixed height here overflowed the fixed window frame and clipped
        // the banner's text.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsStatus: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.09), in: Capsule())
        .fixedSize()
    }
}

struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
