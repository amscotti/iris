import AppKit

extension PillController {
    /// The one reduce-motion rule, shared by the live pill and the Settings
    /// preview: the preference forces it on; otherwise the system decides.
    static func effectiveReduceMotion(forcing settingOn: Bool, system systemOn: Bool) -> Bool {
        settingOn || systemOn
    }

    func refreshEffectMaterial() {
        guard let contentView = panel.contentView else { return }
        var stack = contentView.subviews
        while let view = stack.popLast() {
            if let effect = view as? CapsuleEffectView {
                effect.apply(translucent: lastPillTranslucent)
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}
