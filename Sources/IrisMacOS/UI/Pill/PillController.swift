import AppKit
import Foundation
import IrisCore
import SwiftUI
import os

/// Owns the pill panel and feeds it from orchestrator states.
///
/// Any `TranscriptionService` state stream can be observed here; the pill
/// appears for recording, lingers briefly on finals, and hides on idle and
/// on errors. It never renders text: errors clear the pill and surface
/// through the menu bar instead. The panel instance is held strongly for
/// the lifetime of this controller.
@MainActor
@Observable
public final class PillController {
    private static let finalVisibilityNanoseconds: UInt64 = 1_200_000_000
    private static let fadeSettleNanoseconds: UInt64 = 220_000_000

    let panel = PillPanel()
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "pill")
    private let model = PillViewModel()
    private let tracker = MouseCursorTracker()
    private var observeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = 0
    private var streamGeneration = 0
    private var previewGeneration = 0
    private var following = false
    private var cursorTimerActive = false
    private var isPreviewing = false
    private var reduceMotionOverride = false
    /// One "Dictation finished" per take: a rewrite republishes `.final`
    /// after the pre-rewrite final, and VoiceOver must not hear it twice.
    private var announcedFinished = false
    private var lastWaveformColorHex: String?
    var lastPillTranslucent = true
    /// Holds the observer so its deinit removes it: the controller cannot
    /// remove it itself from a nonisolated `deinit`.
    private let accessibilityToken = NotificationCleanupToken()

    public init() {
        let hostingView = NSHostingView(rootView: PillView(model: model))
        Self.makeTransparent(hostingView)
        panel.contentView = hostingView
        panel.setContentSize(PillPanel.preferredSize)
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        accessibilityToken.value = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemAccessibility() }
        }
    }

    /// Applies persisted pill preferences live. The motion toggle forces
    /// reduced motion on; otherwise the system accessibility setting decides.
    public func applyAppearance(
        reduceMotionOverride: Bool, waveformColorHex: String? = nil, pillTranslucent: Bool = true
    ) {
        self.reduceMotionOverride = reduceMotionOverride
        self.lastWaveformColorHex = waveformColorHex
        self.lastPillTranslucent = pillTranslucent
        model.reduceMotion = Self.effectiveReduceMotion(
            forcing: reduceMotionOverride, system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        model.waveformTint = WaveformTint(hex: waveformColorHex)
        model.pillTranslucent = pillTranslucent
        if model.reduceMotion, cursorTimerActive {
            tracker.stop()
            cursorTimerActive = false
        } else if !model.reduceMotion, !cursorTimerActive, following, panel.isVisible {
            tracker.follow(panel: panel)
            cursorTimerActive = true
        }
        refreshEffectMaterial()
    }

    /// Observes a state stream, replacing any previous observation. The
    /// weak reference is re-taken per element: an `await self?.loop(...)`
    /// helper would promote `self` to strong for the whole (endless)
    /// stream and defeat the weak capture.
    public func observe(_ states: AsyncStream<PushToTalkState>) {
        streamGeneration += 1
        let token = streamGeneration
        observeTask?.cancel()
        endPreview(resetModel: true)
        observeTask = Task { @MainActor [weak self] in
            for await state in states {
                if Task.isCancelled { return }
                guard let self, token == self.streamGeneration else { return }
                self.handle(state)
            }
        }
    }

    public func handle(_ state: PushToTalkState) {
        endPreview(resetModel: true)
        render(state)
    }

    public func handle(_ notice: DictationNotice) {
        endPreview(resetModel: true)
        present(notice)
    }

    private func present(_ notice: DictationNotice) {
        let message = NoticePresentation.message(for: notice)
        let label = NoticePresentation.logLabel(for: notice)
        switch notice.severity {
        case .information: logger.info("Dictation notice: \(label, privacy: .public)")
        case .warning: logger.notice("Dictation notice: \(label, privacy: .public)")
        case .error: logger.error("Dictation notice: \(label, privacy: .public)")
        }
        showNotice(PillNotice(notice: notice))
        announce(message)
    }

    /// Both levels and partials decide whether they start a take before
    /// show() cancels the previous final or notice's pending hide.
    private func prepareListening() -> Bool {
        let startingTake = !model.isRecording || model.notice != nil || hideTask != nil || !following
        if startingTake {
            announcedFinished = false
            announce("Recording")
        }
        show()
        return startingTake
    }

    /// Preview ticks use the renderer directly. Every externally delivered
    /// state enters through handle(), which cancels the walkthrough first.
    private func render(_ state: PushToTalkState) {
        switch state {
        case .idle:
            // A hide scheduled by a final is already pending; stray idles
            // hide an otherwise visible pill.
            guard hideTask == nil else { return }
            hideNow()
        case .recording(let level):
            model.pushLevel(level, startingTake: prepareListening())
        case .partial:
            model.markListening(startingTake: prepareListening())
        case .enhancing:
            if !model.isProcessing || !following { announce("Rewriting") }
            show()
            model.beginProcessing()
        case .final(let text):
            renderFinal(text)
        case .error(let message):
            // Terminal state delivery uses the same typed presentation boundary.
            present(.failure(message))
        }
    }

    /// Scripted capsule walkthrough for reviewing the overlay without input.
    /// Returns false when a live take owns the capsule; the refusal is
    /// announced so the Settings and menu actions are not silent no-ops.
    @discardableResult
    public func preview() -> Bool {
        // A live take owns the model: the walkthrough must not wipe its bars
        // mid-recording. A running preview stays replaceable.
        if !isPreviewing, isInLiveTake {
            announce("Dictation in progress. Finish or cancel it before previewing.")
            return false
        }
        // Own visibility now, before the first tick is scheduled. An older
        // hide/fade continuation may already be queued on the main actor.
        generation += 1
        hideTask?.cancel()
        hideTask = nil
        endPreview()
        previewGeneration += 1
        let token = previewGeneration
        let levels: [Float] = [0.08, 0.15, 0.3, 0.5, 0.65, 0.45, 0.7, 0.35, 0.55, 0.25]
        model.reset()
        isPreviewing = true
        previewTask = Task { @MainActor [weak self] in
            defer {
                if self?.previewGeneration == token {
                    self?.isPreviewing = false
                    self?.previewTask = nil
                }
            }
            guard let self, !Task.isCancelled, self.previewGeneration == token else { return }
            self.render(.recording(level: 0.1))
            for level in levels {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
                self.render(.recording(level: level))
            }
            if Task.isCancelled { return }
            self.render(.enhancing)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            self.render(.final("preview"))
        }
        return true
    }

    // MARK: - Testing seams (internal, read-only; no behavior change)

    var isVisibleForTests: Bool { panel.alphaValue > 0 }
    var hasPendingHideForTests: Bool { hideTask != nil }
    var isFollowingForTests: Bool { following }
    var cursorTimerActiveForTests: Bool { cursorTimerActive }
    var levelHistoryForTests: [Float] { model.levelHistory }
    var isRecordingForTests: Bool { model.isRecording }
    var isProcessingForTests: Bool { model.isProcessing }
    var noticeForTests: PillNotice? { model.notice }
    var isPreviewingForTests: Bool { isPreviewing }
    private(set) var lastAnnouncement: String?

    func clearLastAnnouncementForTests() { lastAnnouncement = nil }

    // MARK: - Private

    private var animated: Bool { !model.reduceMotion }

    /// True while a take's states are still arriving: recording or
    /// rewriting, with no terminal's pending hide. The final's lingering
    /// window and notices are presentation leftovers, not a live take.
    private var isInLiveTake: Bool {
        (model.isProcessing || model.isRecording) && hideTask == nil
    }

    /// Re-reads system Reduce Motion / Reduce Transparency without requiring
    /// a settings save or restart. Reduce Motion freezes the waveform via the
    /// model; Reduce Transparency is re-applied directly so the capsule
    /// material switches even when SwiftUI would not call `updateNSView`.
    private func refreshSystemAccessibility() {
        applyAppearance(
            reduceMotionOverride: reduceMotionOverride,
            waveformColorHex: lastWaveformColorHex,
            pillTranslucent: lastPillTranslucent)
    }

    /// Cancels the scripted walkthrough, if one is running.
    private func endPreview(resetModel: Bool = false) {
        guard previewTask != nil || isPreviewing else { return }
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        if resetModel { model.reset() }
    }

    /// The pill never takes focus, so VoiceOver would otherwise say nothing
    /// when recording starts or a take fails. A scripted preview must not
    /// announce fake recording.
    private func announce(_ message: String) {
        guard !isPreviewing else { return }
        lastAnnouncement = message
        AccessibilityAnnouncement.post(message)
    }

    private func showNotice(_ notice: PillNotice) {
        model.showNotice(notice)
        // Forced: the notice swaps view branches, which must be re-flattened.
        show(force: true)
        scheduleHide(after: notice.visibilityNanoseconds)
    }

    private func show(force: Bool = false) {
        // Already presented with no pending hide: level and partial updates
        // only push into the model. Skip the subview re-flatten, the
        // orderFront, and the fade restart — they run at ~10-20 Hz during
        // recording otherwise.
        // A deactivate hide leaves alpha untouched and isVisible false.
        // Level updates must still order the panel forward in that case.
        if !force, !model.reduceMotion, cursorTimerActive, following, hideTask == nil,
            panel.alphaValue > 0, panel.isVisible
        {
            return
        }
        generation += 1
        hideTask?.cancel()
        hideTask = nil
        // NSHostingView can insert new subviews when PillView swaps
        // TimelineView/Canvas/material branches; re-flatten them so only the
        // rounded capsule paints.
        if let contentView = panel.contentView {
            Self.makeTransparent(contentView)
        }
        // Reduced motion means no interpolated cursor-follow timer. Keep the
        // pill's cursor ownership, but snap instead of animating position.
        if model.reduceMotion {
            if cursorTimerActive {
                tracker.stop()
                cursorTimerActive = false
            }
            tracker.snapToCursor(panel: panel)
        } else {
            if !following {
                // Snap only on the hidden -> visible transition. Re-snapping
                // on every audio level would reset interpolation.
                tracker.snapToCursor(panel: panel)
            }
            if !cursorTimerActive {
                tracker.follow(panel: panel)
                cursorTimerActive = true
            }
        }
        following = true
        panel.reveal(animated: animated)
    }

    private func scheduleHide(after nanoseconds: UInt64) {
        generation += 1
        let current = generation
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.hideNow()
        }
    }

    private func hideNow() {
        generation += 1
        let current = generation
        hideTask?.cancel()
        hideTask = nil
        endPreview()
        following = false
        cursorTimerActive = false
        tracker.stop()
        panel.dismiss(animated: animated)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.fadeSettleNanoseconds)
            guard let self, self.generation == current else { return }
            self.panel.settleHidden()
            self.model.reset()
        }
    }
}

/// Removes a stored NotificationCenter observer when deallocated. A
/// `@MainActor` controller cannot touch its own observer token from a
/// nonisolated `deinit`, so the token lives in this box.
final class NotificationCleanupToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NSObjectProtocol?

    var value: NSObjectProtocol? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    deinit {
        if let token = lock.withLock({ stored }) {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

extension PillController {
    /// The finished take's linger: a stale problem notice (busy-press
    /// guidance adopted while the take was finishing) is superseded,
    /// VoiceOver hears the completion, and the capsule fades out
    /// immediately only after a rewrite. Copied notices describe this
    /// take's insertion and survive.
    private func renderFinal(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing was heard: say so at the cursor, not with stale bars.
            present(.noSpeech)
        } else {
            if model.notice == .problem { model.clearNotice() }
            if !announcedFinished {
                announcedFinished = true
                announce("Dictation finished")
            }
            if model.notice == .copied {
                // The copied notice owns its own linger; show() would cancel
                // its hide timer and the final's shorter one would shrink it.
            } else if model.isProcessing {
                // After a rewrite, the last recording bars are stale. Fade out
                // from the processing cluster instead of flashing them back.
                hideNow()
            } else {
                show()
                scheduleHide(after: Self.finalVisibilityNanoseconds)
            }
        }
    }
}
