import Foundation

/// User-chosen tint for the dictation pill waveform.
///
/// A nil hex is the built-in cyan-to-blue look. Stored values are RRGGBB;
/// invalid strings fall back to the default so a bad payload cannot blank
/// the bars.
public struct WaveformTint: Sendable, Equatable, Hashable {
    public var hex: String?

    public static let `default` = WaveformTint(hex: nil)

    public init(hex: String?) {
        self.hex = Self.normalize(hex)
    }

    public var isDefault: Bool { hex == nil }

    public struct RGB: Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double
    }

    /// sRGB components in 0...1 when this is a custom color.
    public var rgb: RGB? {
        guard let hex else { return nil }
        let chars = Array(hex)
        guard chars.count == 6,
            let red = Int(String(chars[0...1]), radix: 16),
            let green = Int(String(chars[2...3]), radix: 16),
            let blue = Int(String(chars[4...5]), radix: 16)
        else { return nil }
        return RGB(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    public static func normalize(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed.uppercased()
    }

    public static let presets: [WaveformPreset] = [
        WaveformPreset(name: "Blue", hex: nil),
        WaveformPreset(name: "Teal", hex: "14B8A6"),
        WaveformPreset(name: "Green", hex: "34C759"),
        WaveformPreset(name: "Orange", hex: "FF9F0A"),
        WaveformPreset(name: "Purple", hex: "AF52DE"),
        WaveformPreset(name: "Graphite", hex: "8E8E93"),
    ]
}

public struct WaveformPreset: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var hex: String?
    public var id: String { hex ?? "default" }

    public init(name: String, hex: String?) {
        self.name = name
        self.hex = WaveformTint.normalize(hex)
    }
}
