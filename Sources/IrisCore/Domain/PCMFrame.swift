import Foundation

/// One chunk of mono 16-bit PCM audio in the canonical converted form.
///
/// Everything downstream of capture works with this type, so providers always
/// receive Int16 mono PCM at a known sample rate (16 kHz or 24 kHz).
public struct PCMFrame: Sendable, Equatable, Hashable {
    /// Little-endian Int16 samples, mono.
    public var samples: [Int16]
    /// Sample rate in Hz. Supported values: 16000, 24000.
    public var sampleRate: Int
    /// Channel count. Always 1 for the converted canonical form.
    ///
    /// The canonical-form invariant (mono, 16 kHz or 24 kHz) is enforced by
    /// `init(samples:sampleRate:channels:)`, `silence(sampleCount:sampleRate:channels:)`,
    /// and `samplesPerFrame(sampleRate:frameMilliseconds:)` via preconditions.
    /// `sampleRate`/`channels` stay mutable for decoding convenience, so code that
    /// mutates them directly must re-establish the invariant; `durationSeconds`
    /// defensively floors a zero/negative divisor at 1 instead of trapping.
    public var channels: Int

    public init(samples: [Int16], sampleRate: Int = 16000, channels: Int = 1) {
        precondition(sampleRate == 16000 || sampleRate == 24000, "PCMFrame requires sampleRate 16000 or 24000.")
        precondition(channels == 1, "PCMFrame requires mono (channels == 1).")
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var sampleCount: Int { samples.count }

    public var durationSeconds: Double {
        let rate = max(sampleRate, 1) * max(channels, 1)
        return Double(samples.count) / Double(rate)
    }

    /// Normalized root-mean-square level in 0...1, for waveform display.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let normalized = Double(sample) / 32768.0
            sum += normalized * normalized
        }
        return Float(min(1.0, (sum / Double(samples.count)).squareRoot()))
    }

    /// Raw little-endian bytes, ready to stream to a provider transport.
    public func asData() -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let dest = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                dest[index] = sample.littleEndian
            }
        }
        return data
    }

    /// Canonical silence for keeping a stream alive while the key is held.
    public static func silence(sampleCount: Int, sampleRate: Int = 16000, channels: Int = 1) -> PCMFrame {
        precondition(sampleRate == 16000 || sampleRate == 24000, "PCMFrame requires sampleRate 16000 or 24000.")
        precondition(channels == 1, "PCMFrame requires mono (channels == 1).")
        return PCMFrame(
            samples: [Int16](repeating: 0, count: max(sampleCount, 0)), sampleRate: sampleRate, channels: channels)
    }

    /// Samples per streaming frame at the given rate for a 100 ms cadence.
    public static func samplesPerFrame(sampleRate: Int, frameMilliseconds: Double = 100) -> Int {
        precondition(sampleRate > 0, "samplesPerFrame requires a positive sampleRate.")
        precondition(frameMilliseconds > 0, "samplesPerFrame requires a positive frameMilliseconds.")
        return Int((Double(sampleRate) * frameMilliseconds / 1000.0).rounded())
    }
}
