import Foundation
import IrisCore
import os

/// Logs one press's dictation timeline for Console diagnosis.
///
/// The service emits recording and partial states per audio frame, so this
/// box logs transitions only: the first live state (the session was
/// acknowledged and audio is flowing) and the completion event (a final
/// arrived, logged by length — never content — to tell an empty result from
/// a missing one). Any terminal state resets it for the next press. Errors
/// keep their existing menu-bar log path; this box only resets on them.
final class PressTimelineLog: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppIdentity.identifier, category: "dictation")
    private static let latency = Logger(subsystem: AppIdentity.identifier, category: "latency")
    private var live = false
    private var releasedAt: ContinuousClock.Instant?
    private var drainLoggedForRelease = false

    func releaseBegan() {
        lock.withLock {
            releasedAt = ContinuousClock.now
            drainLoggedForRelease = false
        }
    }

    func audioStopped() {
        // Peek on purpose: the release-to-transcript interval in `note(.final)`
        // still needs the same start. Log once per release so a double stop
        // does not emit duplicate drain intervals.
        let start: ContinuousClock.Instant? = lock.withLock {
            guard let start = releasedAt, !drainLoggedForRelease else { return nil }
            drainLoggedForRelease = true
            return start
        }
        guard let start else { return }
        let milliseconds = Self.milliseconds(start.duration(to: .now))
        Self.latency.info("Capture drain: \(milliseconds, privacy: .public) ms.")
    }

    static func rewriteFinished(_ settings: RewriteConfiguration, elapsed: Duration, succeeded: Bool) {
        let milliseconds = milliseconds(elapsed)
        latency.info(
            "Rewrite \(settings.provider.name, privacy: .public), model \(settings.model, privacy: .public), reasoning \(settings.effort.rawValue, privacy: .public): \(milliseconds, privacy: .public) ms (\(succeeded ? "completed" : "failed", privacy: .public))."
        )
    }

    func note(_ state: PushToTalkState) {
        switch state {
        case .idle:
            setLive(false)
        case .final(let text):
            // Single critical section: a next-press `releaseBegan()` cannot
            // slip between the live reset and the timestamp take.
            let start = finishPress()
            if let start {
                let milliseconds = Self.milliseconds(start.duration(to: .now))
                Self.latency.info("Release to transcript: \(milliseconds, privacy: .public) ms.")
            }
            logger.info("Press completed with \(text.count, privacy: .public) characters.")
        case .recording, .partial:
            if setLive(true) {
                logger.info("Press live: session acknowledged, audio flowing.")
            }
        case .enhancing:
            logger.info("Press enhancing: a rewrite prompt is running.")
        case .error:
            _ = finishPress()
        }
    }

    /// Atomically clears the live flag and consumes the release timestamp.
    private func finishPress() -> ContinuousClock.Instant? {
        lock.withLock {
            live = false
            let start = releasedAt
            releasedAt = nil
            drainLoggedForRelease = false
            return start
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    /// Marks the press live or reset. Returns true on the false-to-true edge.
    @discardableResult
    private func setLive(_ value: Bool) -> Bool {
        lock.withLock {
            let edge = value && !live
            live = value
            return edge
        }
    }
}
