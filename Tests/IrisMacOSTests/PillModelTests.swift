import AppKit
import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func levelsClampAndKeepRecentHistory() {
    let model = PillViewModel()
    model.pushLevel(-0.5)
    model.pushLevel(2.5)
    #expect(model.levelHistory == [0, 1])
    for index in 0..<25 {
        model.pushLevel(Float(index) / 100)
    }
    #expect(model.levelHistory.count == PillViewModel.maxLevelBars)
    #expect(model.isRecording)
}

@Test @MainActor func pillModelHoldsLevelsOnly() {
    let model = PillViewModel()
    #expect(model.levelHistory.isEmpty)
    #expect(!model.isRecording)
    model.pushLevel(0.4)
    #expect(model.levelHistory == [0.4])
    #expect(model.isRecording)
    #expect(!model.isProcessing)
    model.beginProcessing()
    #expect(model.isProcessing)
    #expect(!model.isRecording)
    model.pushLevel(0.2)
    #expect(!model.isProcessing)
    #expect(model.isRecording)
    model.reset()
    #expect(model.levelHistory.isEmpty)
    #expect(!model.isRecording)
    #expect(!model.isProcessing)
}

@Test @MainActor func pillPartialMarksListeningWithoutTouchingLevels() {
    let model = PillViewModel()
    model.markListening()
    #expect(model.isRecording)
    #expect(!model.isProcessing)
    #expect(model.levelHistory.isEmpty)
    // A late partial after enhancing returns to recording, not finished.
    model.beginProcessing()
    model.markListening()
    #expect(model.isRecording)
    #expect(!model.isProcessing)
}

@Test @MainActor func pillPanelNeverTakesFocus() {
    let panel = PillPanel()
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.isOpaque)
    #expect(PillChrome.capsuleSize == CGSize(width: 128, height: 40))
    #expect(PillChrome.shadowPadding > PillChrome.shadowRadius)
    #expect(
        PillPanel.preferredSize
            == NSSize(width: PillChrome.panelSize.width, height: PillChrome.panelSize.height))
    #expect(PillPanel.preferredSize.width == PillChrome.capsuleSize.width + PillChrome.shadowPadding * 2)
    #expect(PillPanel.preferredSize.height == PillChrome.capsuleSize.height + PillChrome.shadowPadding * 2)
}

@Test @MainActor func pillPanelChromeStaysTransparent() {
    let panel = PillPanel()
    #expect(!panel.isOpaque)
    #expect(panel.backgroundColor == .clear)
    #expect(!panel.hasShadow)
}

@Test @MainActor func pillChromeStaysSubtle() {
    #expect(PillChrome.borderLineWidth == 1.5)
    #expect(PillChrome.shadowRadius == 8)
    #expect(PillChrome.shadowOffset == .zero)
    #expect(PillChrome.shadowOpacityLight > 0)
    #expect(PillChrome.shadowOpacityLight < 0.25)
    #expect(PillChrome.shadowOpacityDark > 0)
    #expect(PillChrome.shadowOpacityDark < 0.5)
}

@Test @MainActor func cursorAnchorCentersAboveCursorWhenFullyVisible() {
    let panel = NSSize(width: 156, height: 68)
    let visible = NSRect(x: 0, y: 0, width: 2000, height: 2000)
    let origin = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 500, y: 500), visibleFrame: visible)
    // x centers on the cursor; y sits `verticalOffset` above minus the shadow inset (68-40)/2 = 14.
    #expect(origin == NSPoint(x: 500 - 156 / 2, y: 500 + 8 - 14))
}

@Test @MainActor func cursorAnchorClampsToVisibleEdges() {
    let panel = NSSize(width: 156, height: 68)
    let visible = NSRect(x: 0, y: 50, width: 1920, height: 1000)
    let left = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 10, y: 500), visibleFrame: visible)
    #expect(left.x == visible.minX)
    let right = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 1910, y: 500), visibleFrame: visible)
    #expect(right.x == visible.maxX - panel.width)
    let bottom = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 960, y: 0), visibleFrame: visible)
    #expect(bottom.y == visible.minY)
    let top = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 960, y: 2000), visibleFrame: visible)
    #expect(top.y == visible.maxY - panel.height)
}

@Test @MainActor func cursorAnchorCentersOversizePanelOnVisibleFrame() {
    let panel = NSSize(width: 2500, height: 1500)
    let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let origin = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 960, y: 500), visibleFrame: visible)
    #expect(origin == NSPoint(x: (1920 - 2500) / 2, y: (1080 - 1500) / 2))
}

@Test @MainActor func cursorAnchorStaysOnSecondScreenVisibleFrame() {
    let panel = NSSize(width: 156, height: 68)
    let second = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
    let origin = MouseCursorTracker.anchorOrigin(
        panelSize: panel, cursor: NSPoint(x: 2000, y: 500), visibleFrame: second)
    #expect(origin.x >= second.minX)
    #expect(origin.x + panel.width <= second.maxX)
    #expect(origin == NSPoint(x: 2000 - 156 / 2, y: 500 + 8 - 14))
}

@Test @MainActor func cursorStepSnapsNearIdleAndInterpolatesAtFixedRate() throws {
    #expect(MouseCursorTracker.interpolation == 0.28)
    // Already settled: no work for idle ticks.
    #expect(MouseCursorTracker.steppedOrigin(from: NSPoint(x: 5, y: 5), toward: NSPoint(x: 5, y: 5)) == nil)
    // Inside the settle radius: snap to the target.
    #expect(
        MouseCursorTracker.steppedOrigin(from: NSPoint(x: 0, y: 0), toward: NSPoint(x: 0.2, y: 0.1))
            == NSPoint(x: 0.2, y: 0.1))
    // Far away: advance by the fixed 60 Hz interpolation factor.
    let next = try #require(
        MouseCursorTracker.steppedOrigin(from: NSPoint(x: 0, y: 0), toward: NSPoint(x: 100, y: 0)))
    #expect(abs(next.x - 28) < 0.0001)
    #expect(next.y == 0)
}

@Test @MainActor func cursorTrackerStopsCleanly() {
    let tracker = MouseCursorTracker()
    tracker.stop()
    #expect(MouseCursorTracker.verticalOffset == 8)
    #expect(MouseCursorTracker.frameInterval == 1.0 / 60.0)
}

@Test @MainActor func waveformGainLiftsConversationWithoutClipping() {
    // Silence rests near-flat.
    #expect(WaveformView.amplify(0) < 0.2)
    // Quiet speech is visibly above the floor without shouting.
    #expect(WaveformView.amplify(0.08) > 0.35)
    #expect(WaveformView.amplify(0.08) > WaveformView.amplify(0) + 0.2)
    // Conversational volume drives bars through the mid-to-upper range.
    let conversational = WaveformView.amplify(0.15)
    #expect(conversational > 0.4)
    #expect(conversational < 0.75)
    #expect(WaveformView.amplify(0.3) > 0.55)
    // Loud input approaches but never exceeds the ceiling.
    let loud = WaveformView.amplify(1.0)
    #expect(loud > 0.9)
    #expect(loud <= 1.0)
    // Out-of-range input clamps instead of wrapping.
    #expect(WaveformView.amplify(-1) == WaveformView.amplify(0))
    #expect(WaveformView.amplify(5) == WaveformView.amplify(1))
    // The curve never steps down as input rises.
    var previous: CGFloat = 0
    for step in 0...20 {
        let height = WaveformView.amplify(Float(step) / 20)
        #expect(height >= previous)
        previous = height
    }
}

@Test @MainActor func waveformBarsPadAndFreeze() {
    let heights = WaveformView.barHeights(levels: [0.5], count: 4, reduceMotion: false)
    #expect(heights.count == 4)
    #expect(heights[3] == WaveformView.amplify(0.5))
    #expect(heights[0] == WaveformView.floorHeight)
    let frozen = WaveformView.barHeights(levels: [0.9, 0.9], count: 3, reduceMotion: true)
    #expect(frozen == [0.18, 0.18, 0.18])
}

@Test @MainActor func processingBarsTravelThenRestWhenMotionIsReduced() {
    let left = WaveformView.processingBarHeights(count: 20, phase: 0, reduceMotion: false)
    let right = WaveformView.processingBarHeights(count: 20, phase: 0.5, reduceMotion: false)
    let rest = WaveformView.processingBarHeights(count: 20, phase: 0.25, reduceMotion: true)
    #expect(left.count == 20)
    #expect(right.count == 20)
    #expect(rest.count == 20)
    #expect(left[0] > left[19])
    #expect(right[19] > right[0])
    #expect(rest[9] > rest[0])
    #expect(rest[9] > rest[19])
    for height in left + right + rest {
        #expect(height >= WaveformView.floorHeight)
        #expect(height <= WaveformView.processingBarHeight + 0.001)
    }
}

@Test @MainActor func waveformBarColorsStayDefaultUntilATintIsChosen() {
    let original = WaveformView.barColors(tint: .default)
    #expect(original.count == 2)
    let green = WaveformView.barColors(tint: WaveformTint(hex: "34C759"))
    #expect(green.count == 2)
    #expect(green != original)
}

@Test @MainActor func waveformSwatchRoundTripsSRGBHex() {
    #expect(WaveformSwatch.hex(from: WaveformSwatch.color(for: WaveformTint(hex: "34C759"))) == "34C759")
    #expect(WaveformSwatch.color(for: .default) != WaveformSwatch.color(for: WaveformTint(hex: "34C759")))
}

@MainActor func makeTestPillController() -> PillController {
    let controller = PillController()
    // Force synchronous reveal/dismiss so alpha assertions are deterministic.
    controller.applyAppearance(reduceMotionOverride: true)
    return controller
}

@Test @MainActor func pillControllerRecordingShowsAndPushesLevel() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.5))
    #expect(controller.isVisibleForTests)
    #expect(controller.isFollowingForTests)
    #expect(controller.isRecordingForTests)
    #expect(!controller.isProcessingForTests)
    #expect(controller.levelHistoryForTests == [0.5])
    controller.handle(.idle)
}

@Test @MainActor func pillControllerPartialClearsProcessingWithoutTouchingLevels() {
    let controller = makeTestPillController()
    controller.handle(.enhancing)
    #expect(controller.isProcessingForTests)
    controller.handle(.partial("hello"))
    #expect(controller.isVisibleForTests)
    #expect(controller.isRecordingForTests)
    #expect(!controller.isProcessingForTests)
    #expect(controller.levelHistoryForTests.isEmpty)
    controller.handle(.idle)
}

@Test @MainActor func pillControllerEnhancingSetsProcessing() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.4))
    controller.handle(.enhancing)
    #expect(controller.isVisibleForTests)
    #expect(controller.isProcessingForTests)
    #expect(controller.lastAnnouncement == "Rewriting")
    #expect(!controller.isRecordingForTests)
    controller.handle(.idle)
}

@Test @MainActor func pillControllerFinalLingersWhenNotProcessing() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    controller.handle(.final("hello"))
    #expect(controller.isVisibleForTests)
    #expect(controller.hasPendingHideForTests)
    controller.handle(.idle)
}

@Test @MainActor func pillControllerFinalHidesImmediatelyWhenProcessing() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    controller.handle(.enhancing)
    controller.handle(.final("hello"))
    #expect(!controller.isVisibleForTests)
    #expect(!controller.hasPendingHideForTests)
    #expect(!controller.isFollowingForTests)
}

@Test @MainActor func pillControllerErrorShowsANoticeThenHides() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.6))
    #expect(controller.isVisibleForTests)
    controller.handle(.error("boom"))
    // The error replaces the waveform with a notice and hides on a timer.
    #expect(controller.isVisibleForTests)
    #expect(controller.noticeForTests == .problem)
    #expect(!controller.isRecordingForTests)
    #expect(controller.hasPendingHideForTests)
}

@Test @MainActor func pillControllerIdleHidesWhenNothingPending() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.2))
    #expect(controller.isVisibleForTests)
    controller.handle(.idle)
    #expect(!controller.isVisibleForTests)
    #expect(!controller.hasPendingHideForTests)
}

@Test @MainActor func pillControllerIdleDuringPendingHideIsIgnored() {
    let controller = makeTestPillController()
    controller.handle(.recording(level: 0.3))
    controller.handle(.final("hello"))
    #expect(controller.hasPendingHideForTests)
    // A stray idle while the final-linger hide is pending must not hide early.
    controller.handle(.idle)
    #expect(controller.isVisibleForTests)
    #expect(controller.hasPendingHideForTests)
    // Clean up the pending hide so the timer does not leak into other tests.
    controller.handle(.error("cleanup"))
}

@Test @MainActor func pillControllerSecondObserveSupersedesFirst() async {
    let controller = makeTestPillController()
    let (first, firstCont) = AsyncStream<PushToTalkState>.makeStream()
    let (second, secondCont) = AsyncStream<PushToTalkState>.makeStream()
    controller.observe(first)
    firstCont.yield(.recording(level: 0.5))
    // Poll: the suite runs many MainActor tests in parallel, so a fixed
    // 50 ms sleep is flaky. Wait up to ~2 s for the observe task to deliver.
    var delivered = false
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if controller.levelHistoryForTests == [0.5] {
            delivered = true
            break
        }
    }
    #expect(delivered)
    controller.observe(second)
    // Stale event on the replaced stream must be ignored.
    firstCont.yield(.recording(level: 0.1))
    try? await Task.sleep(nanoseconds: 200_000_000)
    #expect(!controller.levelHistoryForTests.contains(0.1))
    // The replacement stream still drives the pill.
    secondCont.yield(.recording(level: 0.9))
    var replaced = false
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if controller.levelHistoryForTests.last == 0.9 {
            replaced = true
            break
        }
    }
    #expect(replaced)
    #expect(controller.isVisibleForTests)
    firstCont.finish()
    secondCont.finish()
    controller.handle(.error("cleanup"))
}

@Test @MainActor func pillControllerPreviewCancelledByError() async {
    let controller = makeTestPillController()
    controller.preview()
    var started = false
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if controller.isVisibleForTests {
            started = true
            break
        }
    }
    #expect(started)
    controller.handle(.error("boom"))
    #expect(controller.noticeForTests == .problem)
    let countAfterCancel = controller.levelHistoryForTests.count
    // Longer than one 120 ms preview step: a cancelled preview pushes nothing
    // more. `hideNow` settles with `reset()` after 220 ms, so the count may
    // drop to zero — it must never grow.
    try? await Task.sleep(nanoseconds: 400_000_000)
    #expect(controller.levelHistoryForTests.count <= countAfterCancel)
    #expect(!controller.isProcessingForTests)
    // Still the error notice, never the resumed walkthrough.
    #expect(controller.noticeForTests == .problem)
}

@Test @MainActor func pillControllerSecondPreviewCancelsFirst() async {
    let controller = makeTestPillController()
    controller.preview()
    try? await Task.sleep(nanoseconds: 50_000_000)
    controller.preview()
    var running = false
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if controller.isVisibleForTests && !controller.levelHistoryForTests.isEmpty {
            running = true
            break
        }
    }
    // The replacement preview is running (not crashed, not doubled to completion).
    #expect(running)
    #expect(controller.isRecordingForTests)
    // Two concurrent sequences would interleave roughly twice as many pushes;
    // allow headroom for slow CI but catch a leaked first sequence.
    #expect(controller.levelHistoryForTests.count <= 11)
    controller.handle(.error("cleanup"))
}
