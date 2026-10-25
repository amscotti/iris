import Foundation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@Test @MainActor func reduceMotionTogglesCursorInterpolationInBothDirections() {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.applyAppearance(reduceMotionOverride: false, systemReduceMotion: false)
    controller.handle(.recording(level: 0.4))
    #expect(controller.cursorTimerActiveForTests)

    controller.applyAppearance(reduceMotionOverride: true, systemReduceMotion: false)
    #expect(!controller.cursorTimerActiveForTests)
    #expect(controller.isRecordingForTests)

    controller.applyAppearance(reduceMotionOverride: false, systemReduceMotion: false)
    #expect(controller.cursorTimerActiveForTests)
    #expect(controller.isRecordingForTests)
}
