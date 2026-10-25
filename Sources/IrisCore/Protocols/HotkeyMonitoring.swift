import Foundation

/// Global push-to-talk hotkey edge events.
///
/// Single active subscriber, like `AudioCapturing.frames()`: each observation
/// starts a fresh stream and the previous one is finished on resubscribe.
/// Delivery is latest-edge (a slow consumer sees the newest press/release,
/// never a replayed stale edge). Monitor failures complete the stream;
/// they are surfaced out-of-band by runtime diagnostics.
public protocol HotkeyMonitoring: Sendable {
    func events() -> AsyncStream<HotkeyEvent>
}
