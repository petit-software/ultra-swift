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
    private let dropIndicator = DropIndicatorView()
    /// Non-nil only while a pane drag is over this canvas.
    private(set) var activeDrop: (paneID: PaneID, target: PaneID, zone: DropZone)?
    /// Set for exactly one layout pass, by the drop-preview path only.
    private var animateNextLayout = false

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

    public init(store: LayoutStore) {
        self.store = store
        self.overlay = DividerOverlayView()
        super.init(frame: .zero)
        wantsLayer = true
        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        addSubview(dropIndicator)
        registerForDraggedTypes([panePasteboardType])
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
    private func focusFirstResponder() {
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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        contentRectObservation = window?.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsLayout = true
                self.overlay.needsLayout = true
            }
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let canvas = layoutBounds
        store.canvasBounds = canvas
        var metrics = store.metrics
        metrics.scale = window?.backingScaleFactor ?? 2

        let result = UltraLayout.layout(displayTree, in: canvas, metrics: metrics)
        currentResult = result

        // A divider drag must track the cursor EXACTLY, so implicit animation stays off for
        // it. A drop preview is the opposite: the panes are supposed to be seen moving
        // aside. `animateNextLayout` is set only by the drop-preview path.
        let animating = animateNextLayout && Token.Motion.reflowDuration > 0
        animateNextLayout = false
        CATransaction.begin()
        if animating {
            CATransaction.setAnimationDuration(Token.Motion.reflowDuration)
            CATransaction.setAnimationTimingFunction(Token.Motion.reflowCurve)
        } else {
            CATransaction.setDisableActions(true)
        }
        for (paneID, frame) in result.frames {
            guard let surface = store.surfaces.existingSurface(for: paneID) else { continue }
            surface.isHidden = false
            // `animator()` is what routes a frame change through the running CATransaction.
            // Assigning `frame` directly would snap even inside an animated transaction.
            if animating {
                surface.animator().frame = frame
            } else {
                surface.frame = frame      // <- the entire rendering step
            }
        }
        for paneID in result.hidden {
            store.surfaces.existingSurface(for: paneID)?.isHidden = true
        }
        overlay.frame = bounds
        CATransaction.commit()

        store.surfaces.setFocused(displayTree.focused)
        store.surfaces.setCanClose(displayTree.paneCount > 1)
        overlay.update(result: result)
    }

    /// Subviews are added and removed ONLY here, and only for panes that genuinely
    /// appeared or disappeared. A resize or a sibling split touches nothing.
    private func reconcile() {
        let live = Set(displayTree.paneIDs)
        for paneID in live where store.surfaces.existingSurface(for: paneID)?.superview !== self {
            let surface = store.surfaces.surface(for: paneID)
            addSubview(surface, positioned: .below, relativeTo: overlay)
        }
        store.surfaces.prune(keeping: live)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // MARK: - Drag to rearrange

    /// Resolve where a drop would land. Pure enough to test: give it a point, get a plan.
    func dropPlan(at point: CGPoint, dragging paneID: PaneID) -> (target: PaneID, zone: DropZone)? {
        guard let target = currentResult.pane(at: point), target != paneID,
              let frame = currentResult.frames[target] else { return nil }
        return (target, DropZone.at(point, in: frame))
    }

    /// The pane id carried by a drag.
    ///
    /// `NSItemProvider(item:typeIdentifier:)` — which is what SwiftUI's `.onDrag` builds —
    /// writes the value as DATA under the type, not as a pasteboard string. Reading it with
    /// `string(forType:)` alone returns empty, so every drop resolved to no pane and
    /// silently did nothing. Both encodings are accepted here.
    private func draggedPane(from info: NSDraggingInfo) -> PaneID? {
        let pasteboard = info.draggingPasteboard
        if let raw = pasteboard.string(forType: panePasteboardType),
           let id = PaneID(uuidString: raw) {
            return id
        }
        guard let data = pasteboard.data(forType: panePasteboardType) else { return nil }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let id = PaneID(uuidString: raw) {
            return id
        }
        // NSItemProvider round-trips an NSString as a property list.
        if let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String,
           let id = PaneID(uuidString: raw) {
            return id
        }
        return nil
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let paneID = draggedPane(from: sender), store.tree.contains(paneID) else { return [] }
        if store.draggingPane != paneID {
            store.draggingPane = paneID
            setDragSource(paneID)
        }
        let point = convert(sender.draggingLocation, from: nil)
        guard let plan = dropPlan(at: point, dragging: paneID) else {
            clearDrop()
            return []
        }
        // Unchanged target and zone: do nothing. Recomputing on every mouse-moved event
        // would restart the reflow animation each frame and the panes would never arrive.
        if let current = activeDrop,
           current.paneID == paneID, current.target == plan.target, current.zone == plan.zone {
            return .move
        }
        // THE preview: the tree exactly as it would be after the drop. Rendering that is
        // what makes the other panes slide aside — they are not being nudged for effect,
        // they are already standing where the drop will actually leave them.
        guard let preview = previewTree(dragging: paneID, plan: plan) else {
            clearDrop()
            return []
        }
        activeDrop = (paneID, plan.target, plan.zone)
        dragTree = preview
        animateNextLayout = true
        // `layoutSubtreeIfNeeded()` is a no-op unless the view is actually marked dirty.
        // Without this the preview tree is set but never laid out, so the panes do not move
        // and `currentResult` stays stale — which also puts the landing outline on the
        // pane's OLD frame.
        needsLayout = true
        layoutSubtreeIfNeeded()

        // The landing outline goes around the dragged pane's NEW frame — which, now that
        // the canvas reflows, is where the pane is already sitting.
        if let landing = currentResult.frames[paneID] {
            dropIndicator.show(landing, animated: true)
        }
        dropIndicator.setAccessibilityLabel(plan.zone.accessibilityDescription)
        return .move
    }

    /// The tree that a drop would produce, or nil if the operation is not legal.
    /// Pure: it copies the tree and never touches the model.
    func previewTree(dragging paneID: PaneID,
                             plan: (target: PaneID, zone: DropZone)) -> LayoutTree? {
        var preview = store.tree
        let ok: Bool
        switch plan.zone {
        case .centre: ok = preview.swap(paneID, plan.target)
        case .edge(let edge): ok = preview.move(paneID, toEdgeOf: plan.target, edge: edge)
        }
        return ok ? preview : nil
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    public override func draggingEnded(_ sender: NSDraggingInfo) { clearDrop() }

    /// Exactly one pane wears the phantom state at a time.
    private func setDragSource(_ paneID: PaneID?) {
        for id in store.tree.paneIDs {
            store.surfaces.existingSurface(for: id)?.isDragSource = (id == paneID)
        }
    }

    private func clearDrop() {
        let hadPreview = dragTree != nil
        activeDrop = nil
        store.draggingPane = nil
        setDragSource(nil)
        dragTree = nil
        dropIndicator.hide()
        // Animate back out of the preview too, so a drag that leaves the window settles
        // instead of snapping. Only when there WAS a preview — a plain clear must not
        // animate an unrelated layout pass.
        if hadPreview {
            animateNextLayout = true
            needsLayout = true
        }
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedPane(from: sender) != nil
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let paneID = draggedPane(from: sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        defer { clearDrop() }
        guard let plan = dropPlan(at: point, dragging: paneID) else { return false }
        // The panes are already standing in the previewed positions, and the committed tree
        // is identical to the preview — so this writes the model without moving anything on
        // screen. The drop looks like the drag simply stopping, which is the point.
        switch plan.zone {
        case .centre: store.swap(paneID, plan.target)
        case .edge(let edge): store.move(paneID, toEdgeOf: plan.target, edge: edge)
        }
        return true
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
