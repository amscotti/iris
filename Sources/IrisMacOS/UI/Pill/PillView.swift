import IrisCore
import SwiftUI

/// A brief at-cursor signal that a take needs attention. The pill never
/// renders text; the full message is in the menu bar.
enum PillNotice: Equatable {
    /// Dictation failed or nothing was inserted.
    case problem
    /// The transcript went to the clipboard instead of the cursor.
    case copied
    /// Informational outcome (e.g. a settings/system cancellation): not a
    /// failure, so it must not render as an orange warning.
    case info

    init(category: DictationNotice.Category) { self = category == .copied ? .copied : .problem }

    init(notice: DictationNotice) {
        self = notice.severity == .information ? .info : PillNotice(category: notice.category)
    }

    var symbol: String {
        switch self {
        case .copied: return "doc.on.clipboard.fill"
        case .info: return "info.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .copied: return "Text copied to the clipboard."
        case .info: return "Dictation cancelled."
        case .problem: return "Dictation needs attention. See the Iris menu."
        }
    }

    var visibilityNanoseconds: UInt64 {
        self == .problem ? 4_000_000_000 : 2_400_000_000
    }
}

/// Observable capsule content: waveform levels, processing mode, or a notice.
@MainActor
@Observable
final class PillViewModel {
    static let maxLevelBars = 20

    var levelHistory: [Float] = []
    var isRecording = false
    var isProcessing = false
    var reduceMotion = false
    var waveformTint = WaveformTint.default
    var pillTranslucent = true

    func pushLevel(_ level: Float, startingTake: Bool = false) {
        markListening(startingTake: startingTake)
        levelHistory.append(min(1, max(0, level)))
        if levelHistory.count > Self.maxLevelBars {
            levelHistory.removeFirst(levelHistory.count - Self.maxLevelBars)
        }
    }

    func beginProcessing() {
        notice = nil
        isProcessing = true
        isRecording = false
    }

    /// Continuing dictation keeps its levels. A new take replaces the previous
    /// notice and bars, including when a partial arrives before its first level.
    func markListening(startingTake: Bool = false) {
        notice = nil
        if startingTake { levelHistory = [] }
        isRecording = true
        isProcessing = false
    }

    var notice: PillNotice?

    func showNotice(_ notice: PillNotice) {
        self.notice = notice
        isRecording = false
        isProcessing = false
    }

    /// Drops a superseded notice while keeping the current bars.
    func clearNotice() {
        notice = nil
    }

    func reset() {
        levelHistory = []
        isRecording = false
        isProcessing = false
        notice = nil
    }
}

/// Capsule metrics. The panel is larger than the capsule so the glow can
/// follow the rounded path instead of being clipped into a rectangle.
enum PillChrome {
    static let capsuleSize = CGSize(width: 128, height: 40)
    static let shadowPadding: CGFloat = 14
    static let borderLineWidth: CGFloat = 1.5
    static let shadowRadius: CGFloat = 8
    static let shadowOffset = CGSize.zero
    static let shadowOpacityLight: CGFloat = 0.18
    static let shadowOpacityDark: CGFloat = 0.35

    static var panelSize: CGSize {
        CGSize(
            width: capsuleSize.width + shadowPadding * 2,
            height: capsuleSize.height + shadowPadding * 2)
    }

    static func borderOpacity(for colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> CGFloat {
        if contrast == .increased { return colorScheme == .dark ? 0.45 : 0.55 }
        return colorScheme == .dark ? 0.12 : 0.14
    }

    static func borderLineWidth(contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 2.5 : borderLineWidth
    }

    static func borderColor(for colorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        let opacity = borderOpacity(for: colorScheme, contrast: contrast)
        return colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}

/// Capsule overlay: waveform bars, or a traveling cluster while enhancing.
///
/// Material is an AppKit visual-effect view masked to a capsule; SwiftUI
/// Material still blurs a rectangle in a non-key panel, which reads as
/// square corners on light desktops.
struct PillView: View {
    var model: PillViewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var statusHint: String {
        Self.statusValue(notice: model.notice, isProcessing: model.isProcessing, isRecording: model.isRecording)
    }

    nonisolated static func statusValue(notice: PillNotice?, isProcessing: Bool, isRecording: Bool) -> String {
        if let notice { return notice.accessibilityHint }
        if isProcessing { return "Rewriting dictation." }
        return isRecording ? "Recording dictation." : "Dictation finished."
    }

    var body: some View {
        ZStack {
            CapsuleMaterial(
                translucent: model.pillTranslucent,
                darkAppearance: colorScheme == .dark
            )
            .frame(width: PillChrome.capsuleSize.width, height: PillChrome.capsuleSize.height)
            if let notice = model.notice {
                Image(systemName: notice.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(notice == .problem ? Color.orange : Color.secondary)
                    .frame(width: PillChrome.capsuleSize.width, height: PillChrome.capsuleSize.height)
            } else {
                WaveformView(
                    levels: model.levelHistory,
                    reduceMotion: model.reduceMotion,
                    tint: model.waveformTint,
                    isProcessing: model.isProcessing
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: PillChrome.capsuleSize.width, height: PillChrome.capsuleSize.height)
            }
            Capsule()
                .strokeBorder(
                    PillChrome.borderColor(for: colorScheme, contrast: colorSchemeContrast),
                    lineWidth: PillChrome.borderLineWidth(contrast: colorSchemeContrast)
                )
                .frame(width: PillChrome.capsuleSize.width, height: PillChrome.capsuleSize.height)
        }
        .frame(width: PillChrome.panelSize.width, height: PillChrome.panelSize.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation")
        // Live status belongs in the value (hints describe actions, and
        // this element has none).
        .accessibilityValue(statusHint)
    }
}
