import Foundation

/// Converted (Int16 mono) audio frames.
///
/// Every press subscribes anew, so each `frames()` stream must keep
/// delivering to its latest subscriber: values yielded after an earlier
/// subscriber stops must still reach the next one.
///
/// Subscription contract:
/// - Single active subscriber per stream. Resubscribing starts a fresh
///   `frames()` stream for the new press; the previous stream is finished
///   (never left half-open, never shared across presses).
/// - `frames()` must not silently drop audio once yielded — size the
///   internal buffer for a press-length take instead.
/// - Capture is non-throwing: stream completion ends frame delivery (both on
///   normal stop and for finite scripted sources), while hardware/device
///   failures are reported out-of-band to `DictationOrchestrator.failCapture`
///   rather than thrown through this signature.
public protocol AudioCapturing: Sendable {
    func frames() -> AsyncStream<PCMFrame>
}
