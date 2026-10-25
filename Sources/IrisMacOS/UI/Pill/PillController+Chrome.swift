import AppKit

extension PillController {
    /// Clears every AppKit layer behind the capsule so only the rounded path
    /// paints. Visual-effect views keep their own capsule mask; flattening
    /// `masksToBounds` on them would show the rectangular blur plate. The
    /// chrome host draws the glow, so its mask stays off.
    static func makeTransparent(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        if view is NSVisualEffectView { return }
        if view is CapsuleChromeView {
            view.layer?.masksToBounds = false
            return
        }
        view.layer?.masksToBounds = false
        for subview in view.subviews {
            makeTransparent(subview)
        }
    }
}
