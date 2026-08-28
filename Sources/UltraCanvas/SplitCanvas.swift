import AppKit
import SwiftUI
import UltraDesign
import UltraLayout

/// The one `NSViewRepresentable` in the app: a single seam between SwiftUI and the canvas.
/// Everything above it is SwiftUI; everything below it is AppKit owning frames.
public struct SplitCanvas: NSViewRepresentable {
    private let store: LayoutStore

    public init(store: LayoutStore) {
        self.store = store
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
        view.sync()
    }
}

/// The canvas, its backdrop, and the window bar.
///
/// The frosted material shows through the gutters between panes and behind the transparent
/// titlebar — that is where the glass reading comes from. Pane content stays opaque.
/// See docs/02-DESIGN-LANGUAGE.md.
public struct CanvasSurface: View {
    private let store: LayoutStore

    public init(store: LayoutStore) {
        self.store = store
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
            SplitCanvas(store: store)
                .id(store.workspaceID)
        }
        // The TOP edge only. Ignoring every edge is what put the canvas underneath the
        // session sidebar: this is a `NavigationSplitView` detail column now, not the whole
        // window, and a view that ignores its leading safe area in one slides straight under
        // the column beside it. The top is still ignored so the backdrop runs behind the
        // transparent titlebar, which is where the glass reading comes from.
        .ignoresSafeArea(edges: .top)
        .background(WindowChrome(theme: store.theme,
                                 title: store.windowTitle) { store.noteWindowFrame($0) })
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
        window.titleVisibility = .hidden
        // Hidden in the titlebar, but still the TAB's label — a row of tabs all reading
        // "Ultra" tells the user nothing about which workspace each one is.
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
/// draws the window's rounded corner and its edge stroke, and once the window gained a
/// sidebar the canvas stopped being the window — so a surface scoped to the canvas drew the
/// window's border around the detail column, as a bordered card sitting next to the sidebar.
///
/// It spans the full window rather than stopping at the titlebar, which is what removes the
/// separate dark block the header used to be — with `fullSizeContentView` and a transparent
/// titlebar, this material is what shows through up there too. The tint is laid ON the
/// material, not mixed into it, so 30% means 30% regardless of what is behind the window.
public struct WindowSurface: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WindowSurfaceView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
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
        layer.masksToBounds = true
        layer.borderWidth = Token.Space.windowBorderWidth

        if tint.superlayer == nil { layer.addSublayer(tint) }
        tint.frame = bounds
        tint.cornerRadius = Token.Space.windowRadius
        tint.cornerCurve = .continuous
        applyColours()
        CATransaction.commit()
        // The shadow is cast from the window's alpha, so it is recomputed whenever the
        // shape changes rather than following a stale rectangle through a resize.
        window?.invalidateShadow()
    }

    /// The border and the tint are both dynamic colours, and `NSColor.cgColor` is where a
    /// dynamic colour COLLAPSES — against whatever appearance is current at that instant,
    /// which outside a draw is the light one whatever the window is wearing.
    private func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.borderColor = Token.Colour.windowBorder.cgColor
            tint.backgroundColor = Token.Colour.windowTint.cgColor
        }
    }

    /// Both colours were flattened against the appearance that was current when they were
    /// last set, so a theme change has to ask for them again. Nothing else invalidates
    /// them: the bounds have not moved, so `layout()` is never called.
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
