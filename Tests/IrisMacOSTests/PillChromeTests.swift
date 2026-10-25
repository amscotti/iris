import SwiftUI
import Testing

@testable import IrisMacOS

@Test @MainActor func pillChromeStrengthensBorderWhenContrastIsIncreased() {
    for scheme in [ColorScheme.light, .dark] {
        #expect(
            PillChrome.borderOpacity(for: scheme, contrast: .increased)
                > PillChrome.borderOpacity(for: scheme, contrast: .standard))
    }
    #expect(
        PillChrome.borderLineWidth(contrast: .increased)
            > PillChrome.borderLineWidth(contrast: .standard))
}

@Test func pillAccessibilityValueNamesEachLiveState() {
    #expect(PillView.statusValue(notice: .info, isProcessing: false, isRecording: false) == "Dictation cancelled.")
    #expect(PillView.statusValue(notice: nil, isProcessing: true, isRecording: false) == "Rewriting dictation.")
    #expect(PillView.statusValue(notice: nil, isProcessing: false, isRecording: true) == "Recording dictation.")
    #expect(PillView.statusValue(notice: nil, isProcessing: false, isRecording: false) == "Dictation finished.")
}

@Test func problemNoticesStayVisibleLongerThanCopiedNotices() {
    #expect(PillNotice.problem.visibilityNanoseconds > PillNotice.copied.visibilityNanoseconds)
}
