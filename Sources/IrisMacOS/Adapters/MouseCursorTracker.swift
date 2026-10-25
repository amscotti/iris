import AppKit
import Foundation

/// Keeps the pill anchored above the cursor with smooth interpolation.
///
/// The target is a few points above the cursor hotspot, clamped to the
/// visible frame of the screen containing the cursor so multi-display
/// setups stay on-screen. Smoothing assumes the fixed 60 Hz `frameInterval`;
/// callers must not reuse `interpolation` at other cadences.
@MainActor
public final class MouseCursorTracker: NSObject {
    public static let verticalOffset: CGFloat = 8
    public static let frameInterval: TimeInterval = 1.0 / 60.0
    /// Distance under which the panel snaps to the cursor target instead of
    /// interpolating, so idle ticks settle instead of drifting forever.
    public static let settleDistance: CGFloat = 0.5

    static let interpolation: CGFloat = 0.28

    private weak var panel: PillPanel?
    private var timer: Timer?
    private var current: NSPoint?

    /// Jumps the panel to the cursor immediately, without smoothing.
    public func snapToCursor(panel: PillPanel) {
        let origin = Self.anchorOrigin(panelSize: panel.frame.size, cursor: NSEvent.mouseLocation)
        current = origin
        panel.setFrameOrigin(origin)
    }

    /// Starts 60 fps interpolated following of the given panel. Callers must
    /// call `stop()` to halt promptly; if the tracker deallocates first, the
    /// timer holds only a weak reference and invalidates itself on its next
    /// tick instead of keeping the tracker alive.
    public func follow(panel: PillPanel) {
        stop()
        self.panel = panel
        current = panel.frame.origin
        let timer = Timer(
            timeInterval: Self.frameInterval, repeats: true,
            block: { [weak self] scheduled in
                guard let self else {
                    scheduled.invalidate()
                    return
                }
                // The timer runs on RunLoop.main; hop onto the MainActor
                // inline instead of allocating a Task per tick (60/s).
                MainActor.assumeIsolated {
                    self.tick()
                }
            })
        // 60 Hz cursor following does not need exact firing; tolerance lets
        // the system coalesce ticks and saves wakeups.
        timer.tolerance = Self.frameInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        panel = nil
        current = nil
    }

    private func tick() {
        guard let panel else {
            stop()
            return
        }
        let target = Self.anchorOrigin(panelSize: panel.frame.size, cursor: NSEvent.mouseLocation)
        let origin = current ?? target
        // `nil` means already settled: skip the redundant move so idle ticks do no work.
        guard let next = Self.steppedOrigin(from: origin, toward: target) else { return }
        current = next
        panel.setFrameOrigin(next)
    }

    /// Next interpolated point toward the target, or `nil` when already there.
    /// Snaps inside `settleDistance` so idle ticks settle instead of drifting;
    /// otherwise advances by `interpolation` (tuned for `frameInterval`).
    static func steppedOrigin(from origin: NSPoint, toward target: NSPoint) -> NSPoint? {
        if origin == target { return nil }
        let delta = NSPoint(x: target.x - origin.x, y: target.y - origin.y)
        if hypot(delta.x, delta.y) < Self.settleDistance { return target }
        let factor = Self.interpolation
        return NSPoint(
            x: origin.x + delta.x * factor,
            y: origin.y + delta.y * factor)
    }

    /// Unclamped anchor point: centered on the cursor, a few points above it.
    static func baseOrigin(panelSize: NSSize, cursor: NSPoint, offset: CGFloat = verticalOffset)
        -> NSPoint
    {
        let shadowInset = max(0, (panelSize.height - PillChrome.capsuleSize.height) / 2)
        return NSPoint(
            x: cursor.x - panelSize.width / 2, y: cursor.y + offset - shadowInset)
    }

    /// Pure anchor math for tests: clamps `baseOrigin` into `visibleFrame`.
    /// Oversized panels center on the visible frame rather than clamping
    /// off-screen. The live `anchorOrigin` below resolves the visible frame
    /// from the screen containing the cursor and delegates here.
    public static func anchorOrigin(
        panelSize: NSSize, cursor: NSPoint, visibleFrame: NSRect, offset: CGFloat = verticalOffset
    ) -> NSPoint {
        var origin = baseOrigin(panelSize: panelSize, cursor: cursor, offset: offset)
        let visible = visibleFrame
        if panelSize.width < visible.width {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panelSize.width)
        } else {
            origin.x = visible.minX + (visible.width - panelSize.width) / 2
        }
        if panelSize.height < visible.height {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - panelSize.height)
        } else {
            origin.y = visible.minY + (visible.height - panelSize.height) / 2
        }
        return origin
    }

    /// Anchor point for a panel of the given size at the cursor position,
    /// clamped into the containing screen's visible frame.
    public static func anchorOrigin(panelSize: NSSize, cursor: NSPoint, offset: CGFloat = verticalOffset)
        -> NSPoint
    {
        let screen =
            NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return baseOrigin(panelSize: panelSize, cursor: cursor, offset: offset)
        }
        return anchorOrigin(panelSize: panelSize, cursor: cursor, visibleFrame: visible, offset: offset)
    }
}
