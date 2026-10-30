import AppKit
import SwiftUI
import UltraDesign
import UltraLayout

/// The one `NSViewRepresentable` in the app: a single seam between SwiftUI and the canvas.
/// Everything above it is SwiftUI; everything below it is AppKit owning frames.
public struct SplitCanvas: NSViewRepresentable {
    private let store: LayoutStore
    private let bottomInset: CGFloat

    public init(store: LayoutStore, bottomInset: CGFloat = 0) {
        self.store = store
        self.bottomInset = bottomInset
    }

    public func makeNSView(context: Context) -> SplitCanvasView {
        SplitCanvasView(store: store)
    }

    public func updateNSView(_ view: SplitCanvasView, context: Context) {
        // Reading the observable tree here is what registers this view's dependency on it,
        // so a split or close from anywhere re-drives layout.
        _ = store.tree
        _ = store.metrics
        // Registers the dependency that makes a pane conversion redraw.
        _ = store.surfaceRevision
        view.bottomInset = bottomInset
        view.sync()
        // Separate from `sync`, which re-asserts focus only as a side effect of the model
        // having changed. This is the model asking for it directly — see
        // `LayoutStore.reclaimKeyboardFocus`.
        view.reclaimKeyboardFocus(revision: store.focusRevision)
    }

    /// The session changed and this canvas is on its way out: see `SplitCanvasView.retire`.
    public static func dismantleNSView(_ view: SplitCanvasView, coordinator: Coordinator) {
        view.retire()
    }
}

/// The canvas, its backdrop, and the window bar.
///
/// The frosted material shows through the gutters between panes and behind the transparent
/// titlebar — that is where the glass reading comes from. Pane content stays opaque.
/// See docs/02-DESIGN-LANGUAGE.md.
public struct CanvasSurface: View {
    private let store: LayoutStore
    private let bottomInset: CGFloat

    /// - `bottomInset`: room to leave under the panes for something the window floats over
    ///   the canvas's bottom edge — the session tab belt. See `SplitCanvasView.bottomInset`.
    public init(store: LayoutStore, bottomInset: CGFloat = 0) {
        self.store = store
        self.bottomInset = bottomInset
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Rebuilt when the SESSION changes, and that is safe for exactly one reason:
            // `PaneSurfaceStore` owns pane views above the view layer, so tearing this
            // canvas down detaches the panes without releasing them — their processes
            // keep running — and the next canvas re-adopts them in `reconcile()`.
            //
            // Rebinding a live `SplitCanvasView` to another store would be the
            // alternative, and it is the one with somewhere for a PTY to get dropped:
            // every cached frame, focus target and drag in flight belongs to the old
            // tree. Identity is the blunter tool and the safer one.
            SplitCanvas(store: store, bottomInset: bottomInset)
                .id(store.workspaceID)
        }
        // The TOP edge only. Ignoring every edge is what put the canvas underneath the
        // session sidebar: this is a `NavigationSplitView` detail column now, not the whole
        // window, and a view that ignores its leading safe area in one slides straight under
        // the column beside it. The top is still ignored so the backdrop runs behind the
        // transparent titlebar, which is where the glass reading comes from.
        .ignoresSafeArea(edges: .top)
        // What macOS calls the window — the same string `RootView` and `PaneWindowView`
        // give `navigationTitle`, so the two writers of `window.title` cannot disagree
        // about what it says. See `LayoutStore.systemWindowTitle`.
        .background(WindowChrome(theme: store.theme,
                                 title: store.systemWindowTitle) { store.noteWindowFrame($0) })
    }
}



/// Configures the host window once it exists: a transparent, full-size-content titlebar so
/// the material is continuous from the very top of the window.
public struct WindowChrome: NSViewRepresentable {
    private let theme: TerminalTheme
    private let title: String
    private let onFrameChange: ((CGRect) -> Void)?

    public init(theme: TerminalTheme, title: String = "Ultra",
                onFrameChange: ((CGRect) -> Void)? = nil) {
        self.theme = theme
        self.title = title
        self.onFrameChange = onFrameChange
    }

    public func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        context.coordinator.onFrameChange = onFrameChange
        DispatchQueue.main.async {
            configure(probe.window)
            context.coordinator.observe(probe.window)
        }
        return probe
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFrameChange = onFrameChange
        configure(nsView.window)
        context.coordinator.observe(nsView.window)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        var onFrameChange: ((CGRect) -> Void)?
        private weak var observed: NSWindow?
        /// Held in a box so the observers are torn down by the box's own nonisolated
        /// deinit — a main-actor deinit cannot touch main-actor state.
        private var observers = ObserverBox()

        func observe(_ window: NSWindow?) {
            guard let window, observed !== window else { return }
            observers = ObserverBox()
            observed = window
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                observers.tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] notification in
                        guard let window = notification.object as? NSWindow else { return }
                        MainActor.assumeIsolated { self?.onFrameChange?(window.frame) }
                    })
            }
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        // Titlebar, backdrop material, glass headers, menus and the palette all resolve
        // from the appearance — pinning it to the terminal theme is what makes the window
        // one continuous surface instead of light chrome around a dark terminal.
        // In "Follow System" the appearance is deliberately NOT pinned: the theme is
        // derived FROM the system appearance, so pinning it back is a loop that never
        // notices the system changing.
        //
        // Guarded on a real change: `configure` runs on every `updateNSView`, and assigning
        // an appearance forces the whole window tree to redraw whether or not it differs.
        // Unguarded, that fired on every layout pass and showed up as the flicker.
        // Compared by NAME rather than by identity — `NSAppearance(named:)` is not
        // documented to vend a shared instance, and an identity check that is always false
        // is a guard that never guards.
        let appearance = Preferences.appAppearance
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // HIDDEN: the project's name is drawn in the middle of the header by the window's
        // content (`WindowHeaderTitle`), and SwiftUI's `.toolbar(removing: .title)` keeps
        // its own title item out of the toolbar. The window still HAS the title — set just
        // below — for the Window menu and Mission Control.
        //
        // Hiding it used to be unstable, because SwiftUI set the title visible again whenever
        // it applied a `navigationTitle`. With the title removed from the toolbar SwiftUI no
        // longer puts it back, and this and that say the same thing.
        window.titleVisibility = .hidden
        // Also what the Window menu and Mission Control call this window.
        window.title = title
        // The toolbar itself comes from SwiftUI's `.toolbar` — it owns the items, so making
        // a second NSToolbar here would fight it. This only picks the STYLE: `.unified` is
        // what gives the tall Finder-style titlebar the traffic lights are placed in.
        window.toolbar?.showsBaselineSeparator = false
        window.toolbarStyle = .unified
        // Native macOS tabs are OFF, because the window now has its own session sidebar and
        // two tab systems in one window is worse than either. A native tab bar also hides
        // itself at one tab, has room for a name only until there are about four, and lives
        // in the one strip the traffic lights already own — see `SessionSidebar`.
        window.tabbingMode = .disallowed
        // MUST stay titled. AppKit masks a titled window to its own corner radius —
        // measured at 15.5pt on macOS 26 — and there is no API to change it, so exceeding
        // that radius means an untitled window. An untitled window cannot become key
        // (verified: the app would not activate and no keystroke reached a shell), and a
        // terminal that cannot take the keyboard is not a terminal. The corner radius is
        // therefore the system's, and the doubled arc is avoided by not drawing a second
        // one — see `RoundedBackdropView`.
        window.styleMask.formUnion([.titled, .fullSizeContentView])
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.invalidateShadow()
        // Dragging inside a pane must never move the window — a terminal owns its content.
        window.isMovableByWindowBackground = false
    }
}

/// The window's own surface: ONE glass material running edge to edge, header included.
///
/// Placed by the APP behind the whole window, not by `CanvasSurface` behind the canvas. It
/// draws the window's rounded corner, and once the window gained a
/// sidebar the canvas stopped being the window — so a surface scoped to the canvas drew the
/// window's border around the detail column, as a bordered card sitting next to the sidebar.
///
/// It spans the full window rather than stopping at the titlebar, which is what removes the
/// separate dark block the header used to be — with `fullSizeContentView` and a transparent
/// titlebar, this material is what shows through up there too. The tint is laid ON the
/// material, not mixed into it, so 30% means 30% regardless of what is behind the window.
public struct WindowSurface: NSViewRepresentable {
    /// The corners rounded to `windowRadius`. All four for the window; a surface that lies
    /// against another inside the window — the session sidebar's — rounds only the corners
    /// that are the window's own, or its square edge would show as a notch.
    private let corners: CACornerMask
    /// The project's colour for the aurora at the foot of the surface, or nil for none —
    /// the sidebar's surface, the Agents overview, a window with no project.
    private let aurora: NSColor?

    public init(corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                         .layerMinXMaxYCorner, .layerMaxXMaxYCorner],
                aurora: NSColor? = nil) {
        self.corners = corners
        self.aurora = aurora
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WindowSurfaceView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.corners = corners
        view.auroraColour = aurora
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        guard let surface = nsView as? WindowSurfaceView else { return }
        surface.corners = corners
        surface.auroraColour = aurora
        nsView.needsLayout = true
    }
}

/// Rounds to `windowRadius`, which MUST be >= the system's 15.5pt mask. A larger radius is
/// strictly inside that mask, so only this arc is ever drawn — the doubled-corner glitch
/// only happens when the radius drawn here is *smaller* than the system's.
final class WindowSurfaceView: NSVisualEffectView {
    /// A sublayer rather than a background colour: `NSVisualEffectView` paints its material
    /// over its own layer's background, so a tint set there would simply not be visible.
    private let tint = CALayer()
    /// The aurora: a radial wash of the project's colour, centred on the bottom edge and
    /// gone by the window's middle. Over the tint, under everything the window holds.
    /// See `Appearance.aurora`.
    private let aurora = CAGradientLayer()
    var corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                 .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    /// The project's colour, or nil for no aurora.
    var auroraColour: NSColor? {
        didSet { guard auroraColour != oldValue else { return }; needsLayout = true }
    }

    /// Its own observer, deliberately.
    ///
    /// Everything else that follows a look setting is reachable from the store — the bridge
    /// walks the panes and pushes. This view is not: it is a leaf inside a SwiftUI
    /// background, with no owner holding a reference to it. Something has to tell it, and
    /// the cheapest something is the notification it can subscribe to itself.
    private let observers = ObserverBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = Appearance.windowMaterial.material
        observers.add(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.material = Appearance.windowMaterial.material
                    self.needsLayout = true
                }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        wantsLayer = true
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = Token.Space.windowRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = corners
        layer.masksToBounds = true

        if tint.superlayer == nil { layer.addSublayer(tint) }
        tint.frame = bounds
        tint.cornerRadius = Token.Space.windowRadius
        tint.cornerCurve = .continuous
        tint.maskedCorners = corners
        if aurora.superlayer == nil { layer.addSublayer(aurora) }
        // Wider than the window and centred on its bottom edge, so the glow is a low arc
        // across the foot rather than a disc in the corner of its own frame. Unit
        // coordinates, origin at the layer's bottom left: the centre sits on the bottom
        // edge's midpoint and the ellipse reaches half the window up.
        //
        // The WINDOW's bounds, not this view's: the sidebar lays its own copy of this
        // surface inside its column, and an arc centred on the column's foot would be a
        // second, smaller aurora beside the first. Placed by the window, the two surfaces
        // draw one arc between them, and the sidebar shows the part that falls on it.
        let frame = window?.contentView.map { convert($0.bounds, from: $0) } ?? bounds
        aurora.frame = frame.insetBy(dx: -frame.width * 0.25, dy: 0)
        aurora.type = .radial
        aurora.startPoint = CGPoint(x: 0.5, y: 0)
        aurora.endPoint = CGPoint(x: 1.0, y: 0.5)
        aurora.locations = [0, 0.45, 1]
        applyColours()
        CATransaction.commit()
        // The shadow is cast from the window's alpha, so it is recomputed whenever the
        // shape changes rather than following a stale rectangle through a resize.
        window?.invalidateShadow()
    }

    /// The tint is a dynamic colour, and `NSColor.cgColor` is where a dynamic colour
    /// COLLAPSES — against whatever appearance is current at that instant, which outside a
    /// draw is the light one whatever the window is wearing.
    ///
    /// No edge stroke. The window used to draw its own 1.5pt border on this layer, on the
    /// reasoning that glass over an arbitrary desktop needs a boundary; the window's own
    /// shadow and the system's mask turned out to be boundary enough, and the stroke read
    /// as a frame around the glass rather than as the glass's edge.
    private func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            tint.backgroundColor = Token.Colour.windowTint.cgColor
            // Off, or no project, or a look that asks for no decoration: the layer is kept
            // but drawn with nothing.
            // Nil is no colour at all, not clear at some strength: `.clear` is black with
            // no alpha, and black at 45% is a shadow in the sidebar's corner.
            let colour = auroraColour ?? .black
            let strength = auroraColour != nil && Appearance.aurora
                && !Token.Environment_.increaseContrast ? Appearance.auroraStrength : 0
            aurora.colors = [colour.withAlphaComponent(strength).cgColor,
                             colour.withAlphaComponent(strength * 0.35).cgColor,
                             colour.withAlphaComponent(0).cgColor]
        }
    }

    /// The colour was flattened against the appearance that was current when it was last
    /// set, so a theme change has to ask for it again. Nothing else invalidates it: the
    /// bounds have not moved, so `layout()` is never called.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyColours()
        CATransaction.commit()
    }
}

// MARK: - Previews
//
// Every fixture, every one named. See docs/05-PREVIEWS.md — a pane you cannot open in the
// Xcode canvas is a pane you can only test by launching the app and building a layout by hand.

#Preview("Single", traits: .fixedLayout(width: 800, height: 500)) {
    CanvasSurface(store: .placeholders(.single))
}

#Preview("Three across", traits: .fixedLayout(width: 1000, height: 400)) {
    CanvasSurface(store: .placeholders(.threeAcross))
}

#Preview("Grid 2×2", traits: .fixedLayout(width: 900, height: 600)) {
    CanvasSurface(store: .placeholders(.grid2x2))
}

#Preview("Sidebar + main", traits: .fixedLayout(width: 1100, height: 700)) {
    CanvasSurface(store: .placeholders(.sidebarMain))
}

#Preview("Deep nest", traits: .fixedLayout(width: 900, height: 700)) {
    CanvasSurface(store: .placeholders(.deepNest))
}

#Preview("Deep nest — dark", traits: .fixedLayout(width: 900, height: 700)) {
    CanvasSurface(store: .placeholders(.deepNest))
        .preferredColorScheme(.dark)
}

#Preview("Narrow — minimum pane sizes", traits: .fixedLayout(width: 420, height: 300)) {
    CanvasSurface(store: .placeholders(.grid2x2))
}

#Preview("Zoomed pane", traits: .fixedLayout(width: 900, height: 600)) {
    let store = LayoutStore.placeholders(.grid2x2)
    store.toggleZoom()
    return CanvasSurface(store: store)
}

#Preview("Six panes", traits: .fixedLayout(width: 1280, height: 800)) {
    let store = LayoutStore.placeholders(.grid2x2)
    let panes = store.tree.paneIDs
    store.split(edge: .bottom, paneID: panes[0])
    store.split(edge: .right, paneID: panes[3])
    store.focus(panes[1])
    return CanvasSurface(store: store)
}
