import AppKit
import UltraDesign
import UltraLayout

/// The canvas. AppKit owns pane frames here, and that is the point.
///
/// SwiftUI gives no hard guarantee about `NSViewRepresentable` lifetime across structural
/// identity changes — and a split *is* a structural identity change. Betting a live PTY on
/// diffing heuristics is not a bet worth taking, so laying out panes is one `setFrame` per
/// pane and nothing else. See docs/01-SPLIT-ENGINE.md § 4.
@MainActor
public final class SplitCanvasView: NSView {
    public let store: LayoutStore
    private let overlay: DividerOverlayView

    /// Transient tree used while a divider is being dragged. The model is not written
    /// during the drag: that keeps `@Observable` quiet, keeps undo to one entry per drag,
    /// and avoids persistence churn.
    var dragTree: LayoutTree?

    private var displayTree: LayoutTree { dragTree ?? store.tree }
    private(set) var currentResult = LayoutResult()

    /// Watches the window's content layout rect.
    ///
    /// `layoutBounds` is derived from `contentLayoutRect`, but this view's OWN bounds span
    /// the full window (the canvas is full-bleed under the transparent titlebar). So when a
    /// tab bar appears or disappears the content rect changes while our bounds do not, and
    /// AppKit never calls `layout()` — the panes stayed under the tab bar until a resize
    /// forced a pass. `contentLayoutRect` is documented as KVO-compliant, so observing it
    /// is what makes adding a tab re-lay-out immediately.
    private var contentRectObservation: NSKeyValueObservation?

    /// The drop preview, created the first time a pane is dragged over the canvas and kept
    /// hidden afterwards rather than rebuilt — a glass view is not free, and a drag produces
    /// a great many updates.
    var dropHighlight: DropHighlightView?

    /// Optional `NSGlassEffectContainerView` around every pane's glass.
    ///
    /// Apple's documented way to make many sibling glass views cheap: it batches them into
    /// one render pass instead of one pass each, which is exactly this canvas's shape — one
    /// glass view per pane. It is OFF by default all the same, because the same view also
    /// merges neighbours within `spacing` and elevates its descendants' z-order, and both
    /// change how the canvas COMPOSITES rather than only how fast it draws.
    ///
    /// The host inside it is flipped, so a pane's frame means the same thing in either
    /// parent and `layout()` does not have to know which one is in use.
    private let glassContainer = NSGlassEffectContainerView()
    private let glassHost = FlippedView()
    private let observers = ObserverBox()

    /// Its own token rather than a slot in `observers`: it is re-registered on every move to
    /// a window, and the box has no way to drop just one of what it holds.
    private var keyObserver: (any NSObjectProtocol)? {
        willSet {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }
    }

    /// Where panes are added. The host when merging is on, the canvas itself otherwise.
    private var paneParent: NSView { Appearance.mergesPaneGlass ? glassHost : self }

    public init(store: LayoutStore) {
        self.store = store
        self.overlay = DividerOverlayView()
        super.init(frame: .zero)
        wantsLayer = true
        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        glassContainer.contentView = glassHost
        glassContainer.autoresizingMask = [.width, .height]
        glassHost.autoresizingMask = [.width, .height]
        addSubview(overlay)
        applyGlassContainer()
        // Its own observer: a look setting does not touch the store, so nothing upstream
        // would drive a sync when the container is switched on or off.
        observers.add(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyGlassContainer()
                    self?.sync()
                }
            })
        setAccessibilityElement(true)
        setAccessibilityRole(.splitGroup)
        setAccessibilityLabel("Pane canvas")
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    /// Pull the current tree in and re-lay out. Called by the representable when the
    /// observed store changes, and by the drag handler on every mouse event.
    public func sync() {
        reconcile()
        needsLayout = true
        focusFirstResponder()
    }

    /// Model focus drives AppKit focus, never the other way round — two sources of truth
    /// for "what does a keystroke act on" is a bug factory.
    func focusFirstResponder() {
        guard let window, window.isKeyWindow,
              let content = store.surfaces.content(for: displayTree.focused),
              let target = Self.keyboardTarget(in: content) else { return }
        guard window.firstResponder !== target else { return }
        window.makeFirstResponder(target)
    }

    /// The view that should actually receive keystrokes for a pane.
    ///
    /// A pane's content is not always the thing that types: a shell pane wraps its terminal
    /// in a padded container, and the container deliberately refuses first-responder status.
    /// Handing the container to `makeFirstResponder` silently does nothing — which is how a
    /// split can leave the caret in the pane you just split away from.
    static func keyboardTarget(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder { return view }
        for subview in view.subviews {
            if let found = keyboardTarget(in: subview) { return found }
        }
        return nil
    }

    /// Panes are laid out inside the window's content layout rect, so they clear the
    /// traffic lights, while the frosted backdrop still runs edge to edge behind the
    /// transparent titlebar. That is where the glass reading comes from: one continuous
    /// material, with the panes floating on it.
    var layoutBounds: CGRect {
        guard let window else { return bounds }
        // An untitled window has no `contentLayoutRect` to subtract — it reports the whole
        // frame — so the window bar's height is reserved explicitly. Without this the panes
        // slide up under the bar and the traffic lights.
        guard window.styleMask.contains(.titled) else {
            var inset = bounds
            inset.origin.y += Token.Space.titleBarHeight
            inset.size.height = max(0, inset.height - Token.Space.titleBarHeight)
            return inset
        }
        let clipped = bounds.intersection(convert(window.contentLayoutRect, from: nil))
        return clipped.isNull || clipped.height < 1 ? bounds : clipped
    }

    /// The last `LayoutStore.focusRevision` acted on, so a re-assert happens once per
    /// request rather than on every `updateNSView` — SwiftUI runs those constantly, and one
    /// that grabbed the keyboard every time would make the sidebar impossible to click.
    private var lastFocusRevision = 0

    /// Put the caret back in the focused pane, one turn of the run loop from now.
    ///
    /// Deferred on purpose. The callers are all UI that has just been clicked — a sidebar
    /// row, a toolbar menu — and AppKit sets ITS first responder as part of finishing that
    /// click. Re-asserting synchronously means racing that; doing it a turn later means
    /// arriving after it.
    /// For the test that holds the once-per-request rule. Not `@testable`-only state: the
    /// property it exposes is private for a reason, and a read-only window onto it is
    /// cheaper than making the whole thing internal.
    var lastFocusRevisionForTesting: Int { lastFocusRevision }

    public func reclaimKeyboardFocus(revision: Int) {
        guard revision != lastFocusRevision else { return }
        lastFocusRevision = revision
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focusFirstResponder() }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([PaneDragType.pasteboard])
        // A window that was not key when the canvas last synced never got its first
        // responder set — `focusFirstResponder` bails on exactly that condition — and
        // nothing re-ran it when the window came forward. AppKit then restores whatever it
        // had, which for a window that never had one is the window itself: a terminal on
        // screen with the caret nowhere, and keystrokes going into the void.
        //
        // Scoped to THIS window, and re-registered every time the view moves, so a canvas
        // that changes windows does not keep listening to the old one.
        keyObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { [weak self] in self?.focusFirstResponder() }
                }
        }
        contentRectObservation = window?.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsLayout = true
                self.overlay.needsLayout = true
            }
        }
        needsLayout = true
    }

    // MARK: Dragging destination

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropHighlight()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropHighlight()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.pane(from: sender) != nil
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDrop(sender)
    }

    public override func layout() {
        super.layout()
        let canvas = layoutBounds
        store.canvasBounds = canvas
        var metrics = store.metrics
        metrics.scale = window?.backingScaleFactor ?? 2

        let result = UltraLayout.layout(displayTree, in: canvas, metrics: metrics)
        currentResult = result

        // Reading order, which is also ⌘1…⌘9 order — the number announced is the number
        // that focuses the pane. Assigned here because only the layout knows the order.
        for (index, paneID) in result.visualOrder.enumerated() {
            store.surfaces.surface(for: paneID).accessibilityOrdinal = index + 1
        }

        // Implicit CALayer animation off: a pane must track the cursor exactly during a
        // divider drag. Nothing animates while dragging.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (paneID, frame) in result.frames {
            guard let surface = store.surfaces.existingSurface(for: paneID) else { continue }
            surface.isHidden = false
            surface.frame = frame          // <- the entire rendering step
        }
        for paneID in result.hidden {
            store.surfaces.existingSurface(for: paneID)?.isHidden = true
        }
        overlay.frame = bounds
        glassContainer.frame = bounds
        glassHost.frame = bounds
        CATransaction.commit()

        store.surfaces.setFocused(displayTree.focused)
        store.surfaces.setCanClose(displayTree.paneCount > 1)
        overlay.update(result: result)
    }

    /// Subviews are added and removed ONLY here, and only for panes that genuinely
    /// appeared or disappeared. A resize or a sibling split touches nothing.
    private func reconcile() {
        let live = Set(displayTree.paneIDs)
        let parent = paneParent
        for paneID in live where store.surfaces.existingSurface(for: paneID)?.superview !== parent {
            let surface = store.surfaces.surface(for: paneID)
            // Below the divider overlay when the canvas is the parent; inside the glass
            // host there is nothing to order against, and the overlay is not its sibling.
            if parent === self {
                addSubview(surface, positioned: .below, relativeTo: overlay)
            } else {
                parent.addSubview(surface)
            }
        }
        store.surfaces.prune(keeping: live)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Install or remove the glass container, and keep its merge distance current.
    ///
    /// Switching it re-parents every pane, which `reconcile()` does on the next `sync()`.
    /// The panes themselves are untouched — a surface is never rebuilt, so a live PTY does
    /// not notice that its view moved to a different superview.
    private func applyGlassContainer() {
        glassContainer.spacing = Appearance.glassMergeSpacing
        let wanted = Appearance.mergesPaneGlass
        guard wanted != (glassContainer.superview === self) else { return }
        if wanted {
            glassContainer.frame = bounds
            glassHost.frame = bounds
            addSubview(glassContainer, positioned: .below, relativeTo: overlay)
        } else {
            glassContainer.removeFromSuperview()
        }
    }

    // MARK: - Pointer

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let paneID = currentResult.pane(at: point) {
            store.focus(paneID)
            focusFirstResponder()
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Dividers

/// Sits above the panes, takes the mouse only over a divider, and publishes each divider
/// as a real accessibility splitter so VoiceOver can resize panes with its standard
/// increment/decrement actions — no custom action required.
@MainActor
final class DividerOverlayView: NSView {
    weak var canvas: SplitCanvasView?
    private var dividers: [DividerFrame] = []
    private var axElements: [DividerAXElement] = []
    private var drag: DragSession?

    struct DragSession {
        let ref: DividerRef
        let axis: Axis
        let containerSize: CGFloat
        let startTree: LayoutTree
        let startPoint: CGPoint
        var applied: CGFloat = 0
        var mode: ResizeMode
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var result = LayoutResult()

    func update(result: LayoutResult) {
        self.result = result
        dividers = result.dividers
        rebuildAccessibilityElements()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Transparent to the mouse except over a divider, so panes receive their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        result.divider(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(divider.hitRect,
                          cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    // MARK: Drag

    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = result.divider(at: point) else { return }

        if event.clickCount == 2 {
            canvas.store.apply("Equalize Panes") { $0.equalize(container: divider.ref.containerID) }
            return
        }

        drag = DragSession(ref: divider.ref,
                           axis: divider.axis,
                           containerSize: divider.containerSize,
                           startTree: canvas.store.tree,
                           startPoint: point,
                           mode: event.modifierFlags.contains(.option) ? .push : .hardStop)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var session = drag, let canvas else { return }
        let point = convert(event.locationInWindow, from: nil)
        // ⌥ can be pressed mid-drag to switch into push mode.
        session.mode = event.modifierFlags.contains(.option) ? .push : .hardStop

        let travelled = session.axis == .horizontal
            ? point.x - session.startPoint.x
            : point.y - session.startPoint.y

        // Ask only for the delta not yet applied, so the divider stays glued to the
        // cursor instead of the cursor drifting away from a divider that has stopped.
        var working = canvas.dragTree ?? session.startTree
        let applied = working.resize(divider: session.ref,
                                     by: travelled - session.applied,
                                     containerSize: session.containerSize,
                                     minPaneSize: canvas.store.metrics.minPaneSize.size(along: session.axis),
                                     mode: session.mode)
        session.applied += applied
        drag = session
        canvas.dragTree = working
        canvas.needsLayout = true      // frames follow the cursor exactly; nothing animates
    }

    override func mouseUp(with event: NSEvent) {
        guard let canvas else { return }
        defer { drag = nil; canvas.dragTree = nil; canvas.needsLayout = true }
        guard drag != nil, let dragged = canvas.dragTree else { return }
        canvas.store.commitDrag(dragged)   // one undo entry for the whole drag
    }

    /// Esc cancels a drag and restores the starting fractions.
    func cancelDrag() {
        guard drag != nil, let canvas else { return }
        drag = nil
        canvas.dragTree = nil
        canvas.needsLayout = true
    }

    var isDragging: Bool { drag != nil }

    // MARK: Accessibility

    private func rebuildAccessibilityElements() {
        axElements = dividers.map { divider in
            let element = DividerAXElement()
            element.setAccessibilityRole(.splitter)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(divider.hitRect)
            element.setAccessibilityValue(divider.fraction)
            element.setAccessibilityOrientation(divider.axis == .horizontal ? .vertical : .horizontal)
            element.setAccessibilityLabel(divider.axis == .horizontal
                                          ? "Vertical pane divider" : "Horizontal pane divider")
            element.divider = divider
            element.overlay = self
            return element
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { axElements }

    /// Nudge one divider — the standard VoiceOver splitter interaction.
    func nudge(_ divider: DividerFrame, by points: CGFloat) {
        guard let canvas else { return }
        canvas.store.apply("Resize Panes") {
            $0.resize(divider: divider.ref, by: points,
                      containerSize: divider.containerSize,
                      minPaneSize: canvas.store.metrics.minPaneSize.size(along: divider.axis)) != 0
        }
    }
}

/// AppKit delivers accessibility actions synchronously on the main thread but declares the
/// overrides nonisolated, so isolation is asserted rather than hopped — hopping would make
/// the action asynchronous and break VoiceOver's expectation of an immediate result.
/// `self` is never touched inside the assertion; only the two Sendable values it needs are.
final class DividerAXElement: NSAccessibilityElement, @unchecked Sendable {
    nonisolated(unsafe) var divider: DividerFrame?
    nonisolated(unsafe) weak var overlay: DividerOverlayView?

    override func accessibilityPerformIncrement() -> Bool { nudge(by: 16) }
    override func accessibilityPerformDecrement() -> Bool { nudge(by: -16) }

    private func nudge(by points: CGFloat) -> Bool {
        guard let divider, let overlay else { return false }
        MainActor.assumeIsolated { overlay.nudge(divider, by: points) }
        return true
    }
}

extension Color_Bridge {}
