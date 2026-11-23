import AppKit
import SwiftUI
import UltraDesign
import UltraLayout

/// The one `NSViewRepresentable` in the app: a single seam between SwiftUI and the canvas.
/// Everything above it is SwiftUI; everything below it is AppKit owning frames.
public struct SplitCanvas: NSViewRepresentable {
    private let store: LayoutStore
    private let bottomInset: CGFloat
    private let topInset: CGFloat?
    private let cornerReserve: CGFloat
    private let leadingTrim: CGFloat

    public init(store: LayoutStore, bottomInset: CGFloat = 0, topInset: CGFloat? = nil,
                cornerReserve: CGFloat = 0, leadingTrim: CGFloat = 0) {
        self.store = store
        self.bottomInset = bottomInset
        self.topInset = topInset
        self.cornerReserve = cornerReserve
        self.leadingTrim = leadingTrim
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
        // The keyboard moving between the canvas and a pane floating over it: which pane
        // reads as focused, and which canvas takes the first responder.
        _ = store.session.floatRevision
        view.bottomInset = bottomInset
        view.topInset = topInset
        view.cornerReserve = cornerReserve
        view.leadingTrim = leadingTrim
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
    private let topInset: CGFloat?
    private let cornerReserve: CGFloat
    private let leadingTrim: CGFloat

    /// - `bottomInset`: room to leave under the panes for something the window floats over
    ///   the canvas's bottom edge — the session tab belt. See `SplitCanvasView.bottomInset`.
    /// - `topInset`: how far under the window's top edge the panes start, or nil for under
    ///   the titlebar. See `SplitCanvasView.topInset`.
    /// - `cornerReserve`: how much of the canvas's top-left corner the window draws over.
    ///   See `SplitCanvasView.cornerReserve`.
    /// - `leadingTrim`: how much of the leading window padding is taken back. See
    ///   `SplitCanvasView.leadingTrim`.
    public init(store: LayoutStore, bottomInset: CGFloat = 0, topInset: CGFloat? = nil,
                cornerReserve: CGFloat = 0, leadingTrim: CGFloat = 0) {
        self.store = store
        self.bottomInset = bottomInset
        self.topInset = topInset
        self.cornerReserve = cornerReserve
        self.leadingTrim = leadingTrim
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
            SplitCanvas(store: store, bottomInset: bottomInset, topInset: topInset,
                        cornerReserve: cornerReserve, leadingTrim: leadingTrim)
                .id(store.workspaceID)
            // The panes floating over the tiling, in the canvas's own coordinates.
            FloatingPanes(store: store)
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
        .background(WindowChrome(theme: store.theme, title: store.systemWindowTitle,
                                 // The main window's canvas is the one given a top inset.
                                 compactTitlebar: topInset != nil && Appearance.compact,
                                 hidesFullScreenBar: topInset != nil) {
            store.noteWindowFrame($0)
        })
    }
}



/// Configures the host window once it exists: a transparent, full-size-content titlebar so
/// the material is continuous from the very top of the window.
public struct WindowChrome: NSViewRepresentable {
    private let theme: TerminalTheme
    private let title: String
    private let onFrameChange: ((CGRect) -> Void)?
    /// Whether the window wears the compact titlebar — the main window's, in the compact
    /// grid. It is what puts the traffic lights 6pt higher and 7pt further in, level with
    /// panes that start at the window's edge.
    private let compactTitlebar: Bool
    /// Whether the bar across the top of the screen is taken off in full screen — the
    /// main window, whose toolbar holds nothing. See `FullScreenTitlebar`.
    private let hidesFullScreenBar: Bool

    public init(theme: TerminalTheme, title: String = "Ultra", compactTitlebar: Bool = false,
                hidesFullScreenBar: Bool = false,
                onFrameChange: ((CGRect) -> Void)? = nil) {
        self.theme = theme
        self.title = title
        self.compactTitlebar = compactTitlebar
        self.hidesFullScreenBar = hidesFullScreenBar
        self.onFrameChange = onFrameChange
    }

    public func makeNSView(context: Context) -> NSView {
        let probe = WindowProbe(frame: .zero)
        context.coordinator.onFrameChange = onFrameChange
        context.coordinator.hidesFullScreenBar = hidesFullScreenBar
        attach(probe, coordinator: context.coordinator)
        return probe
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFrameChange = onFrameChange
        context.coordinator.hidesFullScreenBar = hidesFullScreenBar
        // With this update's values: the theme and the title are the struct's.
        if let probe = nsView as? WindowProbe { attach(probe, coordinator: context.coordinator) }
        configure(nsView.window)
        context.coordinator.observe(nsView.window)
    }

    /// Configures the window when the probe is put IN one, a turn of the run loop later —
    /// SwiftUI is still building the window's toolbar while it adds the view.
    ///
    /// It was one `DispatchQueue.main.async` from `makeNSView`, on the assumption that the
    /// view is in its window a turn after it is made. Usually it is. On a launch slow
    /// enough that it was not, the window was never configured at all, and nothing ran
    /// `updateNSView` to do it later: the compact grid opened under the tall unified
    /// titlebar, the traffic lights 6pt under the controls beside them and into the
    /// sidebar's toggle, and stayed so until something redrew the canvas.
    private func attach(_ probe: WindowProbe, coordinator: Coordinator) {
        probe.onWindow = { [weak probe, weak coordinator] in
            DispatchQueue.main.async {
                guard let window = probe?.window else { return }
                configure(window)
                coordinator?.observe(window)
            }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        var onFrameChange: ((CGRect) -> Void)?
        private weak var observed: NSWindow?
        /// Whether this window shows no titlebar bar in full screen — the main window.
        var hidesFullScreenBar = false
        /// Between being told the window will leave full screen and its having left.
        private var isLeavingFullScreen = false
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
            // The titlebar's own window, on its way down with the menu bar or back: it
            // posts a move for every step.
            observers.tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] notification in
                    let moved = notification.object as? NSWindow
                    MainActor.assumeIsolated {
                        guard let self, let moved, let window = self.observed, moved !== window,
                              self.hidesFullScreenBar, !self.isLeavingFullScreen,
                              window.styleMask.contains(.fullScreen),
                              FullScreenTitlebar.isBar(moved, of: window) else { return }
                        FullScreenTitlebar.sync(for: window)
                    }
                })
            // Full screen: no bar across the top. On every update, because AppKit builds
            // the bar during the transition and moves it as the menu bar comes and goes.
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didUpdateNotification,
                         NSWindow.willExitFullScreenNotification] {
                let leaving = name == NSWindow.willExitFullScreenNotification
                observers.tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] notification in
                        let window = notification.object as? NSWindow
                        MainActor.assumeIsolated {
                            guard let self, let window, self.hidesFullScreenBar else { return }
                            if leaving {
                                self.isLeavingFullScreen = true
                                FullScreenTitlebar.restore(for: window)
                            } else if window.styleMask.contains(.fullScreen), !self.isLeavingFullScreen {
                                FullScreenTitlebar.sync(for: window)
                            } else if !window.styleMask.contains(.fullScreen) {
                                self.isLeavingFullScreen = false
                            }
                        }
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
        // `.unifiedCompact` in the compact grid: the same bar, shorter, with the traffic
        // lights nearer the corner.
        let style: NSWindow.ToolbarStyle = compactTitlebar ? .unifiedCompact : .unified
        if window.toolbarStyle != style { window.toolbarStyle = style }
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

/// Tells `WindowChrome` when it has a window: a representable's view is made before it is
/// in one, and nothing else says when that changes.
private final class WindowProbe: NSView {
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }
}

/// The bar AppKit lays across the top of a full-screen window, taken off.
///
/// A full-screen window's titlebar and toolbar are hosted in a window of AppKit's own
/// along the top of the screen, and it is opaque: a flat grey strip over the top row of
/// pane headers and the head of the sidebar, in a window that is otherwise one surface
/// from edge to edge. Neither `titlebarAppearsTransparent` nor SwiftUI's
/// `toolbarBackgroundVisibility` reaches it on macOS 27, and fading the background views
/// inside it clears the sidebar's half and leaves the rest.
///
/// So the bar's whole window is made transparent. It holds nothing of ours — the main
/// window's toolbar is empty, kept for the titlebar's height — and it is found through
/// the close button, which lives in it while the window is full screen: no class names.
///
/// With the pointer at the top of the screen the menu bar comes down and the bar under
/// it, and THEN it is shown, as a bar: that is where the traffic lights are. It lies
/// over the top of the window's content for as long as the menu bar is down, as any
/// full-screen window's does; the content stays where it is. Moving the content down
/// from under the two was tried, and shipped in 0.40.19: the whole window jumping on a
/// pointer that only brushed the top edge was worse than a bar over one row of headers.
///
/// Hiding the toolbar for the length of full screen was the other way and is not one:
/// the sidebar's list and the canvas are laid out against its safe area.
@MainActor
enum FullScreenTitlebar {
    /// The window hosting `window`'s titlebar while it is full screen, or nil in a window.
    private static func bar(of window: NSWindow) -> NSWindow? {
        guard let bar = window.standardWindowButton(.closeButton)?.window, bar !== window
        else { return nil }
        return bar
    }

    /// Whether `candidate` is the window hosting `window`'s titlebar in full screen. It
    /// posts `didMove` for every step of the menu bar's way down and back.
    static func isBar(_ candidate: NSWindow, of window: NSWindow) -> Bool {
        bar(of: window) === candidate
    }

    /// Shows the bar while the menu bar is down — from the moment the two start down to
    /// the moment they are gone — and hides it otherwise.
    static func sync(for window: NSWindow) {
        guard let bar = bar(of: window) else { return }
        let top = (bar.screen ?? window.screen)?.frame.maxY ?? window.frame.maxY
        let isDown = bar.frame.maxY < top - 0.5
        let alpha: CGFloat = isDown ? 1 : 0
        if bar.alphaValue != alpha { bar.alphaValue = alpha }
        if isDown { back(bar, of: window) }
    }

    /// One opaque colour across the whole bar, and a hairline along its foot. AppKit's
    /// own bar is a solid colour over the canvas and glass over the sidebar, so the
    /// sidebar's head showed through the half lying on it, and nothing marked where the
    /// bar ended and the panes began. Laid directly under the view the traffic lights
    /// are in — found through the close button, like the bar itself — and so over
    /// AppKit's two backgrounds. Setting the bar window's `backgroundColor` does nothing.
    private static func back(_ bar: NSWindow, of window: NSWindow) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview,
              let container = titlebar.superview,
              !container.subviews.contains(where: { $0 is FullScreenBarBacking }) else { return }
        let backing = FullScreenBarBacking(frame: container.bounds)
        backing.autoresizingMask = [.width, .height]
        container.addSubview(backing, positioned: .below, relativeTo: titlebar)
    }

    /// On the way out, so the bar is itself again for whatever AppKit does with it next.
    static func restore(for window: NSWindow) {
        guard let bar = bar(of: window) else { return }
        if bar.alphaValue != 1 { bar.alphaValue = 1 }
        // The backing goes: back in a window, the titlebar is transparent again.
        window.standardWindowButton(.closeButton)?.superview?.superview?.subviews
            .filter { $0 is FullScreenBarBacking }.forEach { $0.removeFromSuperview() }
    }
}

/// What the full-screen bar is drawn on: the window background colour, and a hairline
/// along the bottom edge in the separator colour. Both are the system's dynamic colours,
/// resolved in `updateLayer` — which runs under the view's own appearance, and again
/// when that changes — so the bar is light in a light window and dark in a dark one.
private final class FullScreenBarBacking: NSView {
    private let hairline = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        if hairline.superlayer == nil { layer.addSublayer(hairline) }
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hairline.backgroundColor = NSColor.separatorColor.cgColor
        placeHairline()
    }

    override func layout() {
        super.layout()
        placeHairline()
    }

    /// One pixel, whatever the display's scale: thin, not a rule.
    private func placeHairline() {
        let thickness = 1 / (window?.backingScaleFactor ?? 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.frame = CGRect(x: 0, y: isFlipped ? bounds.height - thickness : 0,
                                width: bounds.width, height: thickness)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Nothing here is clickable: the bar's own views are over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
/// only happens when the radius drawn here is *smaller* than the system's. Square in full
/// screen, where the system's mask is gone too.
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

    /// Whether the window is the screen. A full-screen window has no corners: the system
    /// takes its own mask off, and an arc drawn here would show the desktop's black
    /// through each corner of the display.
    private var isFullScreen = false {
        didSet { guard isFullScreen != oldValue else { return }; needsLayout = true }
    }

    /// The radius drawn: the window's, or none in full screen.
    private var radius: CGFloat { isFullScreen ? 0 : Token.Space.windowRadius }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = Appearance.windowMaterial.material
        // Square from the start of the way in, round again from the start of the way out:
        // the corners belong to the window whenever it is one.
        for (name, full) in [(NSWindow.willEnterFullScreenNotification, true),
                             (NSWindow.didEnterFullScreenNotification, true),
                             (NSWindow.willExitFullScreenNotification, false)] {
            observers.add(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] notification in
                    let window = notification.object as? NSWindow
                    MainActor.assumeIsolated {
                        guard let self, window === self.window else { return }
                        self.isFullScreen = full
                    }
                })
        }
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
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.maskedCorners = corners
        layer.masksToBounds = true

        if tint.superlayer == nil { layer.addSublayer(tint) }
        tint.frame = bounds
        tint.cornerRadius = radius
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
