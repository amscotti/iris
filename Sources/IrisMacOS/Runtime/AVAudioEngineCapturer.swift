@preconcurrency import AVFoundation
import Foundation
import IrisCore
import os

/// Microphone capture failures surfaced to the owner of the capturer.
public enum CaptureError: Error, Sendable, Equatable {
    case unavailable
    case notAuthorized
    case startFailed(String)
}

/// Microphone capture behind a two-stage pipeline: the real-time tap only
/// mono-mixes into pooled storage and forwards it; an off-thread task
/// converts to Int16 mono `PCMFrame` values in 100 ms slices, with a pacer
/// covering stalls. Device changes restart the tap instead of failing.
public actor AVAudioEngineCapturer: AudioCaptureLifecycle {
    /// Sample rates the downstream transport accepts.
    public static let supportedSampleRates = [16000, 24000]

    private static let tapBufferSize: AVAudioFrameCount = 4096
    private static let silencePacerNanoseconds: UInt64 = 100_000_000
    /// A converted-output stall is the only case the pacer covers. The
    /// threshold sits beyond any real device cadence (Bluetooth HFP buffers
    /// arrive about every 170 ms): a partial frame pending between normal
    /// chunks must not be mistaken for a stall.
    static let inputStallSeconds: TimeInterval = 0.3
    /// Native tap arrival has a much wider failure bound. Pacer silence does
    /// not refresh it, so a dead tap still fails even while output continues.
    static let nativeInputFailureSeconds: TimeInterval = 3
    /// Consecutive failed conversions tolerated before the take fails
    /// visibly: real input (silence included) converts to samples, so
    /// five empty conversions in a row prove starvation.
    static let maxEmptyConversions = 5

    let targetSampleRate: Int
    let frameSampleCount: Int

    /// One stream generation per press, so a suspended prior consumer
    /// cannot absorb values meant for the next press.
    private let framesHost = RestartableStream<PCMFrame>()
    private let nativeHost = RestartableStream<NativeChunk>()
    let nativeChunkPool = NativeChunkPool(capacity: 4096)

    private let engine = AVAudioEngine()
    nonisolated let logger = Logger(subsystem: AppIdentity.identifier, category: "audio")
    private var converter: AVAudioConverter?
    private var converterSourceRate: Double = 0
    private var cachedInputFormat: AVAudioFormat?
    private let cachedOutputFormat: AVAudioFormat?
    private var conversionTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    /// Joins an in-flight teardown drain for overlapping second stops.
    private var drainTask: Task<Void, Never>?
    var pendingInt16: [Int16] = []
    /// Converted-output pacing is independent of the native tap heartbeat:
    /// fabricated pacer output must never hide a dead tap.
    var lastConvertedAt = Date.distantPast
    var nativeInputFailureReported = false
    var running = false
    private var configObserver: NSObjectProtocol?
    private var generation = 0
    private var captureTakeID = 0
    private var pendingCaptureTakeID = 0
    var convertedFrameCount = 0
    var silenceFrameCount = 0
    private var conversionHealth = ConversionHealth(failureBound: maxEmptyConversions)
    /// Set from runtime init, invoked from the device-change restart. The
    /// lock keeps that handoff off the actor so startup can install it
    /// without awaiting the capturer.
    private nonisolated let captureFailureLock = NSLock()
    private nonisolated(unsafe) var captureFailureHandler: (@Sendable (Int, String) -> Void)?

    /// Shown when a device change cannot restart the tap. The open take
    /// fails instead of finishing as a success on a partial capture.
    public static let captureInterruptedMessage = "The microphone stopped before dictation finished. Try again."

    public init(targetSampleRate: Int = 16000) {
        let resolved = Self.supportedSampleRates.contains(targetSampleRate) ? targetSampleRate : 16000
        self.targetSampleRate = resolved
        self.frameSampleCount = PCMFrame.samplesPerFrame(sampleRate: resolved)
        self.cachedOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(resolved), channels: 1, interleaved: true)
    }

    /// Canonical converted frames (Int16 mono at the target rate).
    public nonisolated func frames() -> AsyncStream<PCMFrame> { framesHost.currentStream }

    public nonisolated func setCaptureFailureHandler(_ handler: @escaping @Sendable (Int, String) -> Void) {
        captureFailureLock.withLock { captureFailureHandler = handler }
    }

    public func setCaptureGeneration(_ id: Int) async { pendingCaptureTakeID = id }

    func reportCaptureFailure(_ message: String) {
        let handler = captureFailureLock.withLock { captureFailureHandler }
        handler?(captureTakeID, message)
    }

    /// Target rate this capturer converts to.
    public var sampleRate: Int { targetSampleRate }

    /// Starts capture on a fresh stream generation. Stage tasks hold this
    /// actor only per chunk/tick (weak self), keeping `deinit` reachable.
    public func start() async throws {
        let requestedTakeID = pendingCaptureTakeID
        await stop()
        // Apply the new identity only after the old generation has drained;
        // callbacks during that drain still belong to the previous take.
        captureTakeID = requestedTakeID
        // Live TCC, not the cached settings snapshot: engine.start() itself
        // presents the microphone prompt when status is notDetermined, and a
        // system prompt appearing while the hotkey is held freezes the take.
        try requireMicrophoneAuthorized()
        framesHost.rotate()
        nativeHost.rotate()
        pendingInt16.removeAll()
        conversionHealth = ConversionHealth(failureBound: Self.maxEmptyConversions)
        converter?.reset()
        convertedFrameCount = 0
        silenceFrameCount = 0
        generation += 1
        do {
            try installTapAndStartEngine()
        } catch {
            framesHost.finish()
            nativeHost.finish()
            throw error
        }
        running = true
        let startedAt = Date()
        lastConvertedAt = startedAt
        nativeChunkPool.resetNativeInput(at: ProcessInfo.processInfo.systemUptime)
        nativeInputFailureReported = false
        let incoming = nativeHost.currentStream
        let outgoing = framesHost.currentContinuation
        conversionTask = Task { [weak self] in
            for await chunk in incoming {
                guard let self, !Task.isCancelled else { return }
                await self.process(chunk: chunk, into: outgoing)
            }
        }
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.silencePacerNanoseconds)
                guard let self, !Task.isCancelled else { return }
                await self.pacerTick(into: outgoing)
            }
        }
        logger.info("Capture started for press generation \(self.generation).")
    }

    /// Stops capture and ends this press's stream generation. Overlapping
    /// stops wait for the in-flight drain (see `teardownTail`).
    public func stop() async {
        guard running else {
            if let drainTask { await drainTask.value }
            return
        }
        running = false
        silenceTask?.cancel()
        silenceTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        nativeHost.finish()
        let stoppedGeneration = generation
        let conversion = conversionTask
        let drain = Task {
            await self.finishDrain(stoppedGeneration: stoppedGeneration, conversion: conversion)
        }
        drainTask = drain
        await drain.value
    }

    // MARK: - Tap stage

    private func requireMicrophoneAuthorized() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            logger.notice("Microphone start refused: access is not granted.")
            throw CaptureError.notAuthorized
        }
    }

    private func installTapAndStartEngine() throws {
        try requireMicrophoneAuthorized()
        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw CaptureError.unavailable
        }
        input.removeTap(onBus: 0)
        let nativeContinuation = self.nativeHost.currentContinuation
        let chunkPool = nativeChunkPool
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: nativeFormat) { buffer, _ in
            // Empty mono (foreign buffer shape, zero-length frame) is
            // forwarded so the conversion stage counts it, not lost here.
            // Record arrival before queueing/conversion so a backlog cannot
            // masquerade as a dead tap. The timestamp has its own lock.
            chunkPool.markNativeInput()
            // Fill pooled storage in place; conversion returns it to the pool.
            var mono = chunkPool.acquire()
            AVAudioEngineCapturer.monoMix(buffer: buffer, into: &mono)
            nativeContinuation.yield(
                NativeChunk(monoSamples: mono, sourceSampleRate: buffer.format.sampleRate))
        }
        // Configuration changes can be posted by startup itself. Observe
        // before starting so the first device route is never missed.
        observeConfigurationChanges()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer = configObserver {
                NotificationCenter.default.removeObserver(observer)
                configObserver = nil
            }
            throw CaptureError.startFailed(error.localizedDescription)
        }
    }

    // MARK: - Conversion stage

    /// Converts one native chunk and emits full canonical frames. Real
    /// input at any level produces samples, so an empty result is a failed
    /// conversion: it feeds the health tracker (visible take failure once
    /// it persists) and never refreshes `lastConvertedAt`.
    private func process(chunk: NativeChunk, into outgoing: AsyncStream<PCMFrame>.Continuation) {
        var chunk = chunk
        let samples = convert(chunk: chunk)
        // Move the storage out before returning it to the pool so the tap
        // reacquires sole ownership and Array does not copy on write.
        let reusableStorage = chunk.monoSamples
        chunk.monoSamples = []
        nativeChunkPool.release(reusableStorage)
        if running, conversionHealth.record(producedSamples: samples.count) {
            let streak = self.conversionHealth.emptyStreak
            logger.error("Audio conversion produced no samples for \(streak) chunks; failing the take.")
            reportCaptureFailure(Self.captureInterruptedMessage)
        }
        guard !samples.isEmpty else { return }
        lastConvertedAt = Date()
        pendingInt16.append(contentsOf: samples)
        while pendingInt16.count >= frameSampleCount {
            let frame = Array(pendingInt16.prefix(frameSampleCount))
            pendingInt16.removeFirst(frameSampleCount)
            outgoing.yield(PCMFrame(samples: frame, sampleRate: targetSampleRate))
            convertedFrameCount += 1
        }
    }

    func convert(chunk: NativeChunk) -> [Int16] {
        let sourceRate = chunk.sourceSampleRate
        guard sourceRate > 0, !chunk.monoSamples.isEmpty, let outputFormat = cachedOutputFormat else { return [] }
        if converter == nil || converterSourceRate != sourceRate || cachedInputFormat == nil {
            guard
                let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)
            else { return [] }
            cachedInputFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterSourceRate = sourceRate
        }
        guard let converter, let inputFormat = cachedInputFormat else { return [] }
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.monoSamples.count))
        else { return [] }
        inputBuffer.frameLength = AVAudioFrameCount(chunk.monoSamples.count)
        guard let destination = inputBuffer.floatChannelData.map({ $0[0] }) else { return [] }
        chunk.monoSamples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                destination.update(from: base, count: buffer.count)
            }
        }
        // The one-shot convert(to:from:) cannot sample-rate-convert: it raises
        // an uncatchable ObjC exception when the output capacity is smaller
        // than the input length, and otherwise fails with paramErr. The
        // streaming API below reports failures via status instead of raising.
        let capacity =
            AVAudioFrameCount(Double(chunk.monoSamples.count) * Double(targetSampleRate) / sourceRate) + 16
        return resample(inputBuffer, to: outputFormat, frameCapacity: capacity, using: converter)
    }

    /// Runs one input buffer through the streaming converter. Failures
    /// yield no samples; the caller counts consecutive empty conversions
    /// and fails the take visibly once they persist.
    private func resample(
        _ inputBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat,
        frameCapacity capacity: AVAudioFrameCount, using converter: AVAudioConverter
    ) -> [Int16] {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }
        let supply = SingleUseInput(inputBuffer)
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            guard let next = supply.next() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }
        guard status != .error else { return [] }
        let produced = Int(outputBuffer.frameLength)
        guard produced > 0, let source = outputBuffer.int16ChannelData.map({ $0[0] }) else { return [] }
        return Array(UnsafeBufferPointer(start: source, count: produced))
    }

    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.restartAfterConfigurationChange() }
        }
    }

    deinit {
        // stop() is the normal teardown path. The stage tasks hold this
        // actor only per chunk/tick (weak self), so a capturer deallocated
        // without stop() can end them here: cancel, finish the hosts.
        conversionTask?.cancel()
        silenceTask?.cancel()
        nativeHost.finish()
        framesHost.finish()
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
    }
}

extension AVAudioEngineCapturer {
    /// Drains the conversion task; ends the frames stream unless superseded.
    fileprivate func finishDrain(stoppedGeneration: Int, conversion: Task<Void, Never>?) async {
        if let conversion { await conversion.value }
        switch Self.teardownTail(
            stoppedGeneration: stoppedGeneration, currentGeneration: generation,
            pendingSamples: pendingInt16.count)
        {
        case .superseded:
            logger.notice(
                "Capture teardown superseded by generation \(self.generation); the new press keeps its stream.")
        case .finish(let flushPendingSamples):
            conversionTask = nil
            if flushPendingSamples {
                framesHost.currentContinuation.yield(
                    PCMFrame(
                        samples: Self.padTerminalSamples(pendingInt16, to: frameSampleCount),
                        sampleRate: targetSampleRate))
                pendingInt16.removeAll()
                convertedFrameCount += 1
            }
            framesHost.finish()
            let converted = self.convertedFrameCount
            let silence = self.silenceFrameCount
            logger.info("Capture stopped gen \(stoppedGeneration): \(converted) audio, \(silence) silence frames.")
        }
    }

    private func restartAfterConfigurationChange() async {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        do {
            try installTapAndStartEngine()
            let restartedAt = Date()
            lastConvertedAt = restartedAt
            nativeChunkPool.resetNativeInput(at: ProcessInfo.processInfo.systemUptime)
            nativeInputFailureReported = false
            logger.info("Microphone tap restarted after a device change.")
        } catch {
            // The input is gone (device unplugged with no replacement,
            // engine failure). Ending the frames stream is also what a
            // healthy stop does, so the owner hears this failure out of band
            // and fails the open take. stop() itself does not report one.
            logger.error("Microphone tap restart failed; ending the capture generation.")
            reportCaptureFailure(Self.captureInterruptedMessage)
            await stop()
        }
    }

}
