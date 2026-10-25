import AppKit
import Foundation

/// Floating capsule host. Never takes keyboard focus: borderless,
/// non-activating, mouse-transparent, shown with `orderFrontRegardless`.
@MainActor
public final class PillPanel: NSPanel {
    public static let preferredSize = NSSize(
        width: PillChrome.panelSize.width, height: PillChrome.panelSize.height)

    private static let fadeDuration: TimeInterval = 0.18

    public init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Menu-bar apps deactivate whenever another app is focused. The
        // capsule must stay on screen across that; Settings uses the same flag.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .statusBar
        alphaValue = 0
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    public func reveal(animated: Bool = true) {
        orderFrontRegardless()
        setFaded(to: 1, animated: animated)
    }

    public func dismiss(animated: Bool = true) {
        setFaded(to: 0, animated: animated)
    }

    /// Orders out once a fade-out has settled. Safe to call redundantly.
    public func settleHidden() {
        if alphaValue == 0 {
            orderOut(nil)
        }
    }

    private func setFaded(to value: CGFloat, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                self.animator().alphaValue = value
            }
        } else {
            alphaValue = value
        }
    }
}
