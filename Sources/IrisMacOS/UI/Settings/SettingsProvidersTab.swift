import IrisCore
import SwiftUI

/// One source list, one configuration surface. Selecting a row edits that
/// provider; the explicit Use action changes the dictation route.
struct ProvidersTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editingProvider: String?
    @State private var keyDrafts: [String: String] = [:]

    private var selection: Binding<String?> {
        Binding(
            get: { editingProvider ?? environment.settings.providerName },
            set: { if let name = $0 { editingProvider = name } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                SettingsHeading(title: "Providers", subtitle: "Choose where Iris transcribes your speech.")
                Spacer()
                DictationRoute(provider: environment.settings.providerName)
            }
            .padding(24)
            Divider()
            HStack(spacing: 0) {
                providerList
                Divider()
                let name = selection.wrappedValue ?? environment.settings.providerName
                if environment.registry.descriptor(forName: name) == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This provider is unavailable in this build.")
                        SettingsCaption(
                            "Choose a registered provider on the left. Its settings and key will be used for dictation."
                        )
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ProviderDetail(
                        providerName: name,
                        keyDraft: Binding(
                            get: { keyDrafts[name] ?? "" },
                            set: { keyDrafts[name] = $0 })
                    )
                    .id(name)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selection.wrappedValue) {
            let name = selection.wrappedValue ?? environment.settings.providerName
            await environment.loadProviderCredentials(name)
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: selection) {
                ForEach(environment.registry.userFacingProviders, id: \.self) { provider in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name)
                                .font(.headline)
                            Text(ProviderPresentation.keyLabel(environment.credentials.state(for: provider.name)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if provider.name == environment.settings.providerName {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("In use for dictation")
                                .help("In use for dictation")
                        }
                    }
                    .padding(.vertical, 9)
                    .tag(provider.name)
                }
            }
            .listStyle(.sidebar)
            SettingsCaption("Each provider keeps its own key and preferences.")
                .padding(16)
        }
        .frame(width: 180)
    }
}

/// The route is the one distinctive graphic in settings: speech passes
/// through the active provider to become text, matching Iris's single job.
private struct DictationRoute: View {
    let provider: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            Text(provider)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            Image(systemName: "text.cursor")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation uses \(provider)")
        .help("Dictation uses \(provider)")
    }
}
