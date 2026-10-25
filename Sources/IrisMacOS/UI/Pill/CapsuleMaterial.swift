import AppKit
import QuartzCore
import SwiftUI

/// Behind-window blur clipped to a capsule at the layer mask, so the
/// frosted plate cannot show rectangular corners on light desktops.
///
/// SwiftUI `Material` inside a `Capsule` still samples a rectangular
/// visual-effect view; this AppKit view sets an explicit path mask and
/// stays `.active` even though the pill panel is never key.
final class CapsuleEffectView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        apply(translucent: true)
    }

    /// Glass uses the HUD material so the desktop leaks through; solid is
    /// the denser popover plate. System Reduce Transparency always wins.
    func apply(translucent: Bool) {
        let glass = translucent && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = glass ? .hudWindow : .popover
        isEmphasized = !glass
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    private func updateMask() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let radius = min(bounds.width, bounds.height) / 2
        layer.cornerRadius = radius
        layer.masksToBounds = true
        let path = CGPath(
            roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let mask = layer.mask as? CAShapeLayer {
            mask.frame = bounds
            mask.path = path
        } else {
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = path
            layer.mask = mask
        }
    }
}

/// Hosts the frosted capsule and draws the glow on this view, not in
/// SwiftUI. A SwiftUI `compositingGroup` flattens the visual-effect view
/// into an opaque bitmap, which kills behind-window glass.
final class CapsuleChromeView: NSView {
    let effect = CapsuleEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(effect)
        apply(translucent: true, darkAppearance: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(effect)
        apply(translucent: true, darkAppearance: false)
    }

    func apply(translucent: Bool, darkAppearance: Bool) {
        effect.apply(translucent: translucent)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(
            darkAppearance ? PillChrome.shadowOpacityDark : PillChrome.shadowOpacityLight)
        layer?.shadowRadius = PillChrome.shadowRadius
        layer?.shadowOffset = .zero
        updateShadowPath()
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        updateShadowPath()
    }

    private func updateShadowPath() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let radius = min(bounds.width, bounds.height) / 2
        layer.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

struct CapsuleMaterial: NSViewRepresentable {
    var translucent = true
    var darkAppearance = false

    func makeNSView(context: Context) -> CapsuleChromeView {
        let view = CapsuleChromeView()
        view.apply(translucent: translucent, darkAppearance: darkAppearance)
        return view
    }

    func updateNSView(_ nsView: CapsuleChromeView, context: Context) {
        nsView.apply(translucent: translucent, darkAppearance: darkAppearance)
        nsView.needsLayout = true
    }
}
