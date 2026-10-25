import AppKit
import IrisCore
import SwiftUI

// MARK: - General

struct AppearanceTab: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var tint: WaveformTint { environment.settings.waveformTint }

    private var pickerColor: Binding<Color> {
        Binding(
            get: { WaveformSwatch.color(for: tint) },
            set: { newColor in
                guard let hex = WaveformSwatch.hex(from: newColor) else { return }
                let current = WaveformSwatch.hex(from: WaveformSwatch.color(for: tint))
                guard hex != current else { return }
                save(hex: hex)
            })
    }

    var body: some View {
        SettingsPane(title: "Appearance", subtitle: "A quiet indicator that follows along while you dictate.") {
            Form {
                Section("Dictation indicator") {
                    HStack(spacing: 20) {
                        preview
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your dictation pill").font(.headline)
                            SettingsCaption("The bars respond to your voice while recording.")
                        }
                        Spacer()
                        Button("Preview on desktop") { environment.pill.preview() }
                            .disabled(environment.isTakeActive)
                    }
                    .padding(.vertical, 12)
                }
                Section("Waveform color") {
                    HStack(spacing: 8) {
                        ForEach(WaveformTint.presets) { preset in
                            WaveformSwatchButton(
                                preset: preset,
                                isSelected: tint.hex == preset.hex,
                                action: { save(hex: preset.hex) })
                        }
                        ColorPicker("Waveform color", selection: pickerColor, supportsOpacity: false)
                            .labelsHidden()
                            .help("Choose a custom color")
                        Spacer(minLength: 8)
                        Button("Use default") { save(hex: nil) }
                            .disabled(tint.isDefault)
                    }
                    SettingsCaption("Choose a preset or use the color picker for your own tint.")
                }
                Section("Display") {
                    Toggle("Translucent background", isOn: environment.binding(for: \.pillTranslucent))
                    SettingsCaption("Let the desktop show through the indicator. The waveform stays solid.")
                    Toggle("Always reduce motion", isOn: environment.binding(for: \.reduceMotion))
                    SettingsCaption("Use static bars. Iris also respects the macOS Reduce Motion setting.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private var preview: some View {
        WaveformView(
            levels: Self.previewLevels,
            reduceMotion: PillController.effectiveReduceMotion(
                forcing: environment.settings.reduceMotion,
                system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
            tint: tint
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: PillChrome.capsuleSize.width, height: PillChrome.capsuleSize.height)
        .background {
            CapsuleMaterial(
                translucent: environment.settings.pillTranslucent,
                darkAppearance: colorScheme == .dark)
        }
        .overlay {
            Capsule().strokeBorder(
                PillChrome.borderColor(for: colorScheme, contrast: colorSchemeContrast),
                lineWidth: PillChrome.borderLineWidth(contrast: colorSchemeContrast))
        }
        .clipShape(Capsule())
        // The waveform bars are accessibility-hidden; without ignoring
        // children the whole preview is pruned from the VoiceOver tree.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the dictation indicator")
    }

    private static let previewLevels: [Float] = [
        0.12, 0.28, 0.55, 0.4, 0.72, 0.35, 0.6, 0.22, 0.48, 0.3, 0.65, 0.18, 0.42, 0.58, 0.25,
        0.5, 0.33, 0.7, 0.2, 0.45,
    ]

    private func save(hex: String?) {
        var updated = environment.settings
        updated.waveformColorHex = WaveformTint.normalize(hex)
        environment.saveSettings(updated)
    }
}

struct WaveformSwatchButton: View {
    var preset: WaveformPreset
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(WaveformSwatch.color(for: WaveformTint(hex: preset.hex)))
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(.quaternary, lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum WaveformSwatch {
    static func color(for tint: WaveformTint) -> Color {
        if let rgb = tint.rgb {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return Color(red: 0.0, green: 0.478, blue: 1.0)
    }

    static func hex(from color: Color) -> String? {
        let converted = NSColor(color)
        guard let rgb = converted.usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
