import Foundation
import Testing

@testable import IrisCore

@Test func waveformTintNormalizesHexAndRejectsJunk() {
    #expect(WaveformTint.normalize("#14b8a6") == "14B8A6")
    #expect(WaveformTint.normalize("  34C759  ") == "34C759")
    #expect(WaveformTint.normalize(nil) == nil)
    #expect(WaveformTint.normalize("") == nil)
    #expect(WaveformTint.normalize("blue") == nil)
    #expect(WaveformTint.normalize("FFF") == nil)
    #expect(WaveformTint(hex: "#ff9f0a").hex == "FF9F0A")
    #expect(WaveformTint(hex: "nope").isDefault)
}

@Test func waveformTintRGBMatchesNormalizedHex() throws {
    let tint = WaveformTint(hex: "34C759")
    let rgb = try #require(tint.rgb)
    #expect(abs(rgb.red - 52.0 / 255) < 0.0001)
    #expect(abs(rgb.green - 199.0 / 255) < 0.0001)
    #expect(abs(rgb.blue - 89.0 / 255) < 0.0001)
    #expect(WaveformTint.default.rgb == nil)
    #expect(WaveformTint.default.isDefault)
}

@Test func waveformPresetsStartWithDefaultBlue() {
    #expect(WaveformTint.presets.first?.hex == nil)
    #expect(WaveformTint.presets.first?.name == "Blue")
    #expect(WaveformTint.presets.contains(where: { $0.hex == "34C759" && $0.name == "Green" }))
    #expect(Set(WaveformTint.presets.map(\.id)).count == WaveformTint.presets.count)
}
