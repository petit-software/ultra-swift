import AppKit
import UltraDesign

/// A vertical ramp of blur behind a pane's title: none at the bottom edge, full at the top.
///
/// Implemented with `CALayer.backgroundFilters` — a true backdrop blur — rather than an
/// `NSVisualEffectView`. That distinction is the whole reason this type exists twice over:
/// a visual-effect view has to SAMPLE what is behind it, and it cannot sample glass. A shell
/// pane paints nothing (`TerminalTheme.backgroundOpacity` is 0), so the only thing behind its
/// header is the pane's `NSGlassEffectView`, and the effect view came back empty — the blur
/// was invisible on exactly the panes that had no opaque content. A background filter runs on
/// the composited backdrop instead, so it works the same over glass, over a terminal grid,
/// and over an opaque tile.
@MainActor
final class HeaderBlurView: NSView {
    private let ramp = CAGradientLayer()
    /// A faint darkening that rides with the blur.
    ///
    /// Blur alone separates text from a BUSY backdrop; over a near-uniform one it does almost
    /// nothing, and a pane's header often sits over exactly that. The tint is what keeps the
    /// title legible in both cases, and it is the part that still shows under Reduce
    /// Transparency, where the blur is dropped.
    private let tint = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        guard let layer else { return }
        layer.masksToBounds = true

        if !Token.Environment_.reduceTransparency,
           let blur = CIFilter(name: "CIGaussianBlur",
                               parameters: [kCIInputRadiusKey: Token.Space.headerBlurRadius]) {
            layer.backgroundFilters = [blur]
        }

        // Layer coordinates put y = 0 at the bottom, so both ramps run clear → full upwards.
        ramp.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor]
        ramp.startPoint = CGPoint(x: 0.5, y: 0)
        ramp.endPoint = CGPoint(x: 0.5, y: 1)
        // Most of the ramp is spent low, so the top of the header is solid rather than
        // fading all the way out under the words.
        ramp.locations = [0, 0.85]
        layer.mask = ramp

        tint.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                       NSColor.black.withAlphaComponent(Token.Space.headerTintOpacity).cgColor]
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ramp.frame = bounds
        tint.frame = bounds
        CATransaction.commit()
    }

    /// Both the filter radius and the tint are set once at construction, so a settings
    /// change has to rebuild them. Reduce Transparency still wins: it drops the blur and
    /// leaves the tint doing the work on its own.
    func refreshAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if Token.Environment_.reduceTransparency {
            layer?.backgroundFilters = []
        } else if let blur = CIFilter(name: "CIGaussianBlur",
                                      parameters: [kCIInputRadiusKey: Token.Space.headerBlurRadius]) {
            layer?.backgroundFilters = [blur]
        }
        tint.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                       NSColor.black.withAlphaComponent(Token.Space.headerTintOpacity).cgColor]
        CATransaction.commit()
    }

    /// Decorative. The header above it takes every click, including the drag to rearrange.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
