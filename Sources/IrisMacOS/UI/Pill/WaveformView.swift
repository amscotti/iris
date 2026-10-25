import Foundation
import IrisCore
import SwiftUI

/// Animated volume bars driven by recent RMS levels in 0...1.
///
/// Listening uses a soft-saturating gain curve. Processing (rewrite) stops
/// the meter and ping-pongs a three-bar cluster in the same tint.
struct WaveformView: View {
    var levels: [Float]
    var reduceMotion = false
    var barCount = 20
    var tint = WaveformTint.default
    var isProcessing = false

    /// Gain applied before the soft ceiling, so conversational volume lands
    /// in the mid-to-upper bar range.
    static let levelGain = 7.5
    /// A gentle perceptual lift makes quieter speech more visible while
    /// preserving silence and the smooth ceiling for louder peaks.
    static let levelResponseExponent = 0.95
    /// Resting bar height for silence, keeping idle near-flat.
    static let floorHeight: CGFloat = 0.12
    /// Peak height of the traveling processing cluster.
    static let processingBarHeight: CGFloat = 0.55
    /// Bars lit as the traveling cluster.
    static let processingClusterCount = 3
    /// One left-right-left cycle while enhancing.
    static let processingPeriod: TimeInterval = 1.1

    /// Normalized bar heights in 0...1. A soft-saturating curve lifts quiet
    /// input without hard-clipping loud input. Reduced motion renders static
    /// bars.
    static func barHeights(levels: [Float], count: Int, reduceMotion: Bool) -> [CGFloat] {
        guard !reduceMotion else { return [CGFloat](repeating: 0.18, count: count) }
        let recent = levels.suffix(count).map { amplify($0) }
        if recent.count >= count { return recent }
        return [CGFloat](repeating: floorHeight, count: count - recent.count) + recent
    }

    /// Maps one clamped 0...1 level through the gain curve.
    static func amplify(_ level: Float) -> CGFloat {
        let clamped = min(1, max(0, Double(level)))
        let response = pow(clamped, levelResponseExponent)
        return floorHeight + (1 - floorHeight) * (1 - exp(-levelGain * response))
    }

    /// Processing meter: a three-bar bump that travels, or a centered rest
    /// when motion is reduced. `phase` is 0...1 for one round trip.
    static func processingBarHeights(count: Int, phase: CGFloat, reduceMotion: Bool) -> [CGFloat] {
        let cluster = CGFloat(processingClusterCount)
        let minCenter = (cluster - 1) / 2
        let maxCenter = CGFloat(max(0, count - 1)) - minCenter
        let center: CGFloat
        if reduceMotion || maxCenter <= minCenter {
            center = (minCenter + maxCenter) / 2
        } else {
            let ping = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let eased = ping * ping * (3 - 2 * ping)
            center = minCenter + (maxCenter - minCenter) * eased
        }
        let halfWidth = cluster / 2 + 0.5
        return (0..<count).map { index in
            let influence = max(0, 1 - abs(CGFloat(index) - center) / halfWidth)
            return floorHeight + (processingBarHeight - floorHeight) * influence
        }
    }

    static func processingPhase(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSinceReferenceDate
        let unit = elapsed.truncatingRemainder(dividingBy: processingPeriod) / processingPeriod
        return CGFloat(unit < 0 ? unit + 1 : unit)
    }

    var body: some View {
        Group {
            if isProcessing && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    barsCanvas(
                        heights: Self.processingBarHeights(
                            count: barCount,
                            phase: Self.processingPhase(at: timeline.date),
                            reduceMotion: false))
                }
            } else {
                barsCanvas(
                    heights: isProcessing
                        ? Self.processingBarHeights(count: barCount, phase: 0, reduceMotion: true)
                        : Self.barHeights(levels: levels, count: barCount, reduceMotion: reduceMotion)
                )
            }
        }
        .frame(width: 104, height: 28)
        .accessibilityHidden(true)
    }

    /// Default bars stay cyan-into-blue. A custom tint uses a lighter mix
    /// of the same hue so the bars still read as a volume gradient.
    static func barColors(tint: WaveformTint) -> [Color] {
        guard let rgb = tint.rgb else { return [.cyan, .blue] }
        let highlight = Color(
            red: rgb.red + (1 - rgb.red) * 0.4,
            green: rgb.green + (1 - rgb.green) * 0.4,
            blue: rgb.blue + (1 - rgb.blue) * 0.4)
        return [highlight, Color(red: rgb.red, green: rgb.green, blue: rgb.blue)]
    }

    private func barsCanvas(heights: [CGFloat]) -> some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
            let gradient = Gradient(colors: Self.barColors(tint: tint))
            for (index, value) in heights.enumerated() {
                let height = max(3, value * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap),
                    y: (size.height - height) / 2,
                    width: width,
                    height: height)
                let path = Path(roundedRect: rect, cornerRadius: width / 2)
                context.fill(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: (size.height - height) / 2),
                        endPoint: CGPoint(x: 0, y: (size.height + height) / 2),
                        options: []))
            }
        }
    }
}
