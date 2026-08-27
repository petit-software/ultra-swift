import AppKit
import SwiftUI

/// A vertical ramp of blur along one edge of a tile: nothing at the far edge, full at the
/// near one.
///
/// Implemented with `CALayer.backgroundFilters` — a true backdrop blur — rather than an
/// `NSVisualEffectView`. That distinction is the whole reason this type exists: a
/// visual-effect view has to SAMPLE what is behind it, and it cannot sample glass. A shell
/// pane paints nothing (`TerminalTheme.backgroundOpacity` is 0), so the only thing behind its
/// header is the pane's `NSGlassEffectView`, and the effect view came back empty — the blur
/// was invisible on exactly the panes that had no opaque content. A background filter runs on
/// the composited backdrop instead, so it works the same over glass, over a terminal grid,
/// and over an opaque tile.
///
/// Lives in UltraDesign because both ends of a tile use it now: the canvas draws it under a
/// pane header, and a tile footer draws it flipped.
@MainActor
public final class EdgeBlurView: NSView {
    /// Which edge the material is solid at.
    public enum Edge: Sendable { case top, bottom }

    private let ramp = CAGradientLayer()
    /// A faint darkening that rides with the blur.
    ///
    /// Blur alone separates text from a BUSY backdrop; over a near-uniform one it does almost
    /// nothing, and a pane's header often sits over exactly that. The tint is what keeps the
    /// title legible in both cases, and it is the part that still shows under Reduce
    /// Transparency, where the blur is dropped.
    private let tint = CAGradientLayer()
    private let edge: Edge
    private let observers = ObserverBox()

    public init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        guard let layer else { return }
        layer.masksToBounds = true
        applyBlur()

        // Layer coordinates put y = 0 at the BOTTOM, so a header ramps clear → full going up
        // and a footer runs the other way. Everything else about the two is identical.
        //
        // The MASK is black at both stops because a mask reads alpha only — its colour is
        // meaningless and must not follow the appearance.
        let clear = NSColor.black.withAlphaComponent(0).cgColor
        let solid = NSColor.black.cgColor

        ramp.colors = edge == .top ? [clear, solid] : [solid, clear]
        ramp.startPoint = CGPoint(x: 0.5, y: 0)
        ramp.endPoint = CGPoint(x: 0.5, y: 1)
        // Most of the ramp is spent away from the solid edge, so the near edge stays solid
        // rather than fading all the way out under the words.
        ramp.locations = edge == .top ? [0, 0.85] : [0.15, 1]
        layer.mask = ramp

        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(tint)
        applyTint()

        // Its own observer, for the same reason `WindowSurfaceView` has one: this is a leaf
        // nobody holds, so nothing can push a changed radius or tint down to it.
        observers.add(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyBlur()
                    self?.applyTint()
                }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A radius of zero means no filter at all rather than a filter doing nothing — an
    /// identity `CIGaussianBlur` still costs a render pass per frame.
    private func applyBlur() {
        let radius = Token.Space.headerBlurRadius
        guard !Token.Environment_.reduceTransparency, radius > 0,
              let blur = CIFilter(name: "CIGaussianBlur",
                                  parameters: [kCIInputRadiusKey: radius])
        else {
            layer?.backgroundFilters = []
            return
        }
        layer?.backgroundFilters = [blur]
    }

    /// The tint's colour is the one thing here that has an appearance: it darkens a header
    /// in dark appearance and lightens one in light. A flat black ramp put a smudge under
    /// every title in Light mode, which is the opposite of the separation it exists for.
    ///
    /// Re-resolved rather than set once, because `CGColor` cannot be dynamic — the value on
    /// the layer is whatever the appearance was when it was last asked for.
    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            let base = Token.Colour.headerTint
            let clear = base.withAlphaComponent(0).cgColor
            let solid = base.withAlphaComponent(Token.Space.headerTintOpacity).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tint.colors = edge == .top ? [clear, solid] : [solid, clear]
            CATransaction.commit()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ramp.frame = bounds
        tint.frame = bounds
        CATransaction.commit()
    }

    /// Decorative. Whatever sits above it takes every click.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `EdgeBlurView` for SwiftUI, so a tile can put the same ramp behind its footer that the
/// canvas puts behind a pane header.
public struct EdgeBlur: NSViewRepresentable {
    let edge: EdgeBlurView.Edge

    public init(edge: EdgeBlurView.Edge) { self.edge = edge }

    public func makeNSView(context: Context) -> EdgeBlurView { EdgeBlurView(edge: edge) }
    public func updateNSView(_ nsView: EdgeBlurView, context: Context) {}
}
