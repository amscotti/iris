@preconcurrency import AVFoundation
import Foundation
import IrisCore
import os

/// Pure capture decisions and math, factored out of `AVAudioEngineCapturer`
/// so cadence, health, and teardown-ownership behavior is unit-testable
/// without a live input device. Nothing here touches engine state.
extension AVAudioEngineCapturer {
    /// One cheap copy of tap audio handed to the conversion stage.
    struct NativeChunk: Sendable {
        var monoSamples: [Float]
        var sourceSampleRate: Double
    }

    /// Single-shot input supply for one streaming converter call. The
    /// converter invokes the block synchronously on the calling thread, so no
    /// locking is needed; the unchecked conformance covers the handoff.
    final class SingleUseInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next() -> AVAudioPCMBuffer? {
            guard let buffer else { return nil }
            self.buffer = nil
            return buffer
        }
    }

    /// Reusable Float storage for tap-to-conversion handoff. The audio
    /// thread acquires an already-allocated array, fills it in place, and
    /// the conversion stage returns that same storage after consuming it.
    /// A short lock protects only the free list; acquired storage has one
    /// owner until it is released, so samples need no synchronization.
    final class NativeChunkPool: @unchecked Sendable {
        private let lock = NSLock()
        private var available: [[Float]]
        private var nativeInputAt = -Double.greatestFiniteMagnitude
        private let capacity: Int
        private let maxPooled: Int
        private let uptime: @Sendable () -> Double

        init(
            capacity: Int, pooledCount: Int = 8,
            uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.capacity = capacity
            self.maxPooled = max(pooledCount, 1)
            self.uptime = uptime
            self.available = (0..<max(pooledCount, 1)).map { _ in
                [Float](repeating: 0, count: capacity)
            }
        }

        func acquire() -> [Float] {
            lock.withLock { available.popLast() } ?? [Float](repeating: 0, count: capacity)
        }

        func release(_ storage: [Float]) {
            lock.withLock {
                if available.count < maxPooled { available.append(storage) }
            }
        }

        /// Updated synchronously by the tap, before any conversion queueing.
        /// Monotonic uptime avoids false stalls after wall-clock changes.
        func markNativeInput(at timestamp: Double? = nil) {
            lock.withLock { nativeInputAt = timestamp ?? uptime() }
        }

        func resetNativeInput(at timestamp: Double) {
            lock.withLock { nativeInputAt = timestamp }
        }

        func secondsSinceNativeInput(now timestamp: Double? = nil) -> TimeInterval {
            lock.withLock { (timestamp ?? uptime()) - nativeInputAt }
        }
    }

    /// Pads a short trailing remainder with silence so the terminal frame
    /// keeps the canonical 100 ms (`frameSampleCount`) length downstream
    /// expects. `stop()` can only leave fewer than `frameSampleCount`
    /// samples behind because the conversion loop emits full frames.
    nonisolated static func padTerminalSamples(_ samples: [Int16], to frameSampleCount: Int) -> [Int16] {
        guard samples.count < frameSampleCount else { return samples }
        return samples + [Int16](repeating: 0, count: frameSampleCount - samples.count)
    }

    /// Averages all channels of a tap buffer into mono Float samples.
    /// Non-float buffer shapes (Int16/interleaved hardware formats) and
    /// zero-length frames produce no samples — an empty result the
    /// conversion stage counts as a failed conversion.
    nonisolated static func monoMix(buffer: AVAudioPCMBuffer) -> [Float] {
        var storage: [Float] = []
        _ = monoMix(buffer: buffer, into: &storage)
        return storage
    }

    /// In-place form used by the real-time tap. Existing capacity is
    /// retained; storage grows only when a larger hardware buffer arrives.
    @discardableResult
    nonisolated static func monoMix(buffer: AVAudioPCMBuffer, into storage: inout [Float]) -> Int {
        guard let channels = buffer.floatChannelData else {
            storage.removeAll(keepingCapacity: true)
            return 0
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            storage.removeAll(keepingCapacity: true)
            return 0
        }
        // Interleaved multi-channel data has no per-channel pointers:
        // channels[1...] would read outside the single interleaved block.
        // Treat it as a failed conversion (mono interleaved is identical
        // in memory to non-interleaved, so it still converts below).
        guard !(buffer.format.isInterleaved && channelCount > 1) else {
            storage.removeAll(keepingCapacity: true)
            return 0
        }
        if storage.count < frameCount {
            storage.append(contentsOf: repeatElement(Float(0), count: frameCount - storage.count))
        } else if storage.count > frameCount {
            storage.removeLast(storage.count - frameCount)
        }
        if channelCount == 1 {
            storage.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: channels[0], count: frameCount)
            }
            return frameCount
        }
        for index in 0..<frameCount { storage[index] = 0 }
        for channel in 0..<channelCount {
            let source = channels[channel]
            for index in 0..<frameCount {
                storage[index] += source[index]
            }
        }
        let scale = 1.0 / Float(channelCount)
        for index in 0..<frameCount {
            storage[index] *= scale
        }
        return frameCount
    }

    /// Consecutive-empty-conversion tracker. Healthy silence still converts
    /// to real (quiet) samples; only failed conversions — non-float buffer
    /// formats, converter errors, allocation failures — produce none, and a
    /// bound of those must fail the take instead of starving it into a
    /// silent no-speech.
    struct ConversionHealth: Equatable {
        private(set) var emptyStreak = 0
        let failureBound: Int

        init(failureBound: Int) {
            self.failureBound = failureBound
        }

        /// Records one conversion. True exactly once per failure run, when
        /// the bound is first reached.
        mutating func record(producedSamples: Int) -> Bool {
            if producedSamples > 0 {
                emptyStreak = 0
            } else {
                emptyStreak += 1
            }
            return emptyStreak == failureBound
        }
    }

    /// Pure native-tap watchdog decision. Every arriving chunk refreshes the
    /// native timestamp, including silent PCM; only its age and the per-
    /// generation latch participate here, never fabricated pacer output.
    static func shouldReportNativeInputStall(
        secondsSinceNativeInput: TimeInterval, alreadyReported: Bool
    ) -> Bool {
        !alreadyReported && secondsSinceNativeInput >= nativeInputFailureSeconds
    }

    /// Tail decision for a stop whose conversion task finished draining:
    /// only a stop whose generation is still current may flush leftovers
    /// and end the frames stream — a press that started while the drain
    /// was suspended owns that stream now, and finishing it would end the
    /// new take after a fabricated frame.
    enum TeardownTail: Equatable {
        case finish(flushPendingSamples: Bool)
        case superseded
    }

    /// Pure teardown decision, factored so the overlap is testable.
    static func teardownTail(
        stoppedGeneration: Int, currentGeneration: Int, pendingSamples: Int
    ) -> TeardownTail {
        guard stoppedGeneration == currentGeneration else { return .superseded }
        return .finish(flushPendingSamples: pendingSamples > 0)
    }

    /// One pacer cadence tick; the task body in `start()` holds the actor
    /// only for this call.
    func pacerTick(into outgoing: AsyncStream<PCMFrame>.Continuation) {
        guard running else { return }
        let now = Date()
        if Self.shouldReportNativeInputStall(
            secondsSinceNativeInput: nativeChunkPool.secondsSinceNativeInput(
                now: ProcessInfo.processInfo.systemUptime),
            alreadyReported: nativeInputFailureReported)
        {
            nativeInputFailureReported = true
            logger.error("Native microphone tap stalled; failing the take instead of pacing silence forever.")
            reportCaptureFailure(Self.captureInterruptedMessage)
        }
        switch Self.pacerAction(
            pendingSamples: pendingInt16.count, frameSampleCount: frameSampleCount,
            secondsSinceInput: now.timeIntervalSince(lastConvertedAt))
        {
        case .none:
            return
        case .silence:
            outgoing.yield(PCMFrame.silence(sampleCount: frameSampleCount, sampleRate: targetSampleRate))
            silenceFrameCount += 1
        case .flushPartial:
            // Real samples are waiting mid-frame: send them (padded), not silence.
            let samples = Self.padTerminalSamples(pendingInt16, to: frameSampleCount)
            outgoing.yield(PCMFrame(samples: samples, sampleRate: targetSampleRate))
            pendingInt16.removeAll()
            convertedFrameCount += 1
        }
    }

    /// What the keep-alive pacer should do on one tick.
    enum PacerAction: Equatable {
        case none
        /// No input for the stall threshold and nothing captured: keep the
        /// provider stream open with a silent frame.
        case silence
        /// Input stalled with real samples still waiting: flush them as one
        /// padded frame so their order is preserved and the meter reflects
        /// them, before any silence follows.
        case flushPartial
    }

    /// Pure pacer decision, factored so cadence behavior is testable.
    static func pacerAction(
        pendingSamples: Int, frameSampleCount: Int, secondsSinceInput: TimeInterval
    ) -> PacerAction {
        guard secondsSinceInput >= inputStallSeconds else { return .none }
        return pendingSamples > 0 ? .flushPartial : .silence
    }
}
