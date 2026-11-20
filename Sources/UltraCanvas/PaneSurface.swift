import AppKit
import SwiftUI
import UltraDesign

/// A pane's surface, for something that is not a pane but sits among them: the session
/// sidebar's panel. The frost a tiled pane wears with the glass off — the same material,
/// from the same source, under the wash of a pane that does not have the keyboard — at a
/// pane's corners, so the panel and the panes beside it are one colour.
///
/// With Settings ▸ Glass panes on there is no frost to match and this is not used: the
/// panel is glass, as the panes are.
public struct PaneSurface: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView { PaneSurfaceView() }
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        (nsView as? PaneSurfaceView)?.apply()
    }
}

final class PaneSurfaceView: NSVisualEffectView {
    /// A sublayer, not a background colour: the material is painted over the view's own.
    private let wash = CALayer()
    /// Its own observer, for the reason `WindowSurfaceView` has one: a leaf inside a
    /// SwiftUI view, with nothing holding a reference to push a setting to it.
    private let observers = ObserverBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        apply()
        observers.add(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    /// Every setting a frosted pane draws with — see `PaneContainerView.applyAppearance`
    /// and `applyBackdrop`, which this follows.
    func apply() {
        material = Appearance.frostMaterial.material
        blendingMode = Appearance.frostSource.blending
        state = Appearance.frostAlwaysActive ? .active : .followsWindowActiveState
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = Token.Space.paneRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        if wash.superlayer == nil { layer.addSublayer(wash) }
        wash.frame = bounds
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        wash.backgroundColor = (isDark
            ? NSColor.black.withAlphaComponent(Appearance.frostUnfocusedTintDark)
            : NSColor.white.withAlphaComponent(Appearance.frostUnfocusedTintLight)).cgColor
        CATransaction.commit()
    }
}
