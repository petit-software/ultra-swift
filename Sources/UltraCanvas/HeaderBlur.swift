import AppKit
import UltraDesign

/// A vertical ramp of blur: none at the bottom edge, full at the top.
///
/// Implemented as a material masked by a gradient rather than a variable-radius blur. A true
/// per-pixel radius ramp needs private CoreAnimation filters; masking the material's alpha
/// reads the same at this size — 36pt — and uses nothing that can be withdrawn.
@MainActor
final class HeaderBlurView: NSVisualEffectView {
    private let ramp = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .headerView
        // Within, not behind: the thing worth blurring is the pane's own content sliding up
        // under the title, not the desktop.
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true

        ramp.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                       NSColor.black.cgColor]
        // Layer coordinates put y = 0 at the bottom, so this runs clear → opaque upwards.
        ramp.startPoint = CGPoint(x: 0.5, y: 0)
        ramp.endPoint = CGPoint(x: 0.5, y: 1)
        // Most of the ramp happens in the lower half, so the top of the header is solidly
        // legible rather than fading all the way up.
        ramp.locations = [0, 0.85]
        layer?.mask = ramp

        if Token.Environment_.reduceTransparency { isHidden = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ramp.frame = bounds
        CATransaction.commit()
    }

    /// Decorative. The header above it takes every click, including the drag to rearrange.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
