import Foundation
import Observation
import Testing

@testable import IrisCore
@testable import IrisMacOS

@MainActor
private func waitForPreview(_ controller: PillController, levels: Int = 1) async throws {
    let changes = AsyncStream.makeStream(of: Void.self)
    let waiting = Task { @MainActor in
        var input = changes.stream.makeAsyncIterator()
        while !Task.isCancelled {
            let count = withObservationTracking {
                controller.levelHistoryForTests.count
            } onChange: {
                changes.continuation.yield(())
            }
            if count >= levels { return }
            guard await input.next() != nil else { throw CancellationError() }
        }
        throw CancellationError()
    }
    defer {
        waiting.cancel()
        changes.continuation.finish()
    }
    try await AsyncDeadline.run(seconds: 5) { try await waiting.value }
}

@Test @MainActor func replacementPreviewRemainsOwnedAndCanBeCancelledByAnError() async throws {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.preview()
    try await waitForPreview(controller)
    controller.preview()
    // The replacement has advanced beyond its initial tick; the old task's
    // cancellation/defer must not clear the new handle or preview flag.
    try await waitForPreview(controller, levels: 2)
    #expect(controller.isPreviewingForTests)
    #expect(controller.lastAnnouncement == nil)
    controller.handle(.error("real failure"))
    #expect(!controller.isPreviewingForTests)
    #expect(controller.noticeForTests == .problem)
    #expect(controller.lastAnnouncement == "real failure")
    try await Task.sleep(for: .milliseconds(400))
    #expect(controller.noticeForTests == .problem)
    #expect(!controller.isRecordingForTests)
    #expect(!controller.isProcessingForTests)
}

@Test @MainActor func directlyDeliveredRecordingSupersedesPreviewTicks() async throws {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.preview()
    try await waitForPreview(controller)
    // AppEnvironment delivers snapshots through handle(), not observe().
    controller.handle(.recording(level: 0.83))
    #expect(!controller.isPreviewingForTests)
    #expect(controller.lastAnnouncement == "Recording")
    #expect(controller.levelHistoryForTests == [0.83])
    try await Task.sleep(for: .milliseconds(400))
    #expect(controller.levelHistoryForTests == [0.83])
    #expect(controller.isRecordingForTests)
    #expect(!controller.isProcessingForTests)
}

@Test @MainActor func anErrorDuringPreviewIsAnnouncedBeforeItsTaskRetires() async throws {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.preview()
    try await waitForPreview(controller)
    #expect(controller.lastAnnouncement == nil)
    controller.handle(.error("provider disconnected"))
    // Cancellation does not run the preview's defer synchronously; the public
    // delivery path must clear preview state before announcing the real error.
    #expect(controller.lastAnnouncement == "provider disconnected")
    #expect(!controller.isPreviewingForTests)
}

@Test @MainActor func typedInsertionNoticeCancelsPreviewAndSurvivesItsNextTick() async throws {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.preview()
    try await waitForPreview(controller)
    #expect(controller.isPreviewingForTests)
    #expect(controller.lastAnnouncement == nil)

    let notice = DictationNotice.insertion(.secureField)
    controller.handle(notice)

    #expect(!controller.isPreviewingForTests)
    #expect(controller.noticeForTests == .copied)
    #expect(controller.isVisibleForTests)
    #expect(controller.hasPendingHideForTests)
    #expect(controller.levelHistoryForTests.isEmpty)
    #expect(!controller.isRecordingForTests)
    #expect(!controller.isProcessingForTests)
    #expect(controller.lastAnnouncement == NoticePresentation.message(for: notice))
    // Wait past the preview's 120 ms tick: a stale tick would replace the notice with bars.
    try await Task.sleep(for: .milliseconds(300))
    #expect(!controller.isPreviewingForTests)
    #expect(controller.noticeForTests == .copied)
    #expect(controller.levelHistoryForTests.isEmpty)
    #expect(!controller.isRecordingForTests)
    #expect(!controller.isProcessingForTests)
    #expect(controller.lastAnnouncement == NoticePresentation.message(for: notice))
}

@Test @MainActor func previewDuringALiveTakeDoesNotWipeTheModel() async throws {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.handle(.recording(level: 0.4))
    controller.handle(.recording(level: 0.7))
    #expect(controller.preview() == false)
    // Refusal is announced while the take's model remains untouched.
    #expect(controller.lastAnnouncement == "Dictation in progress. Finish or cancel it before previewing.")
    #expect(!controller.isPreviewingForTests)
    #expect(controller.levelHistoryForTests == [0.4, 0.7])
    #expect(controller.noticeForTests == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(controller.levelHistoryForTests == [0.4, 0.7])
    #expect(controller.isRecordingForTests)
    // A rewriting take is equally live.
    controller.handle(.enhancing)
    #expect(controller.preview() == false)
    #expect(controller.lastAnnouncement == "Dictation in progress. Finish or cancel it before previewing.")
    #expect(!controller.isPreviewingForTests)
    #expect(controller.isProcessingForTests)
}

@Test @MainActor func previewOwnsVisibilityBeforeItsFirstTickCanRun() async throws {
    let controller = makeTestPillController()
    defer { controller.handle(.idle) }
    controller.handle(.recording(level: 0.4))
    controller.handle(.final("earlier take"))
    #expect(controller.hasPendingHideForTests)
    controller.preview()
    // No await has allowed the new preview task to execute. Its request must
    // already invalidate a hide belonging to the earlier take.
    #expect(!controller.hasPendingHideForTests)
    #expect(controller.isPreviewingForTests)
    try await waitForPreview(controller, levels: 2)
    #expect(controller.isVisibleForTests)
    #expect(controller.isRecordingForTests)
    #expect(controller.isPreviewingForTests)
}
