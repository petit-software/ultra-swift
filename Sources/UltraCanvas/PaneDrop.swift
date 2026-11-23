import AppKit
import UltraDesign
import UltraLayout

/// The highlight shown while a pane is being dragged.
///
/// A plain wash of the label colour — what the sidebar shows for the place a dragged
/// project would land in — sized to where the pane will ACTUALLY land: a half for an
/// edge, the whole pane for a swap, a full side for a root split. Previewing the zone that
/// was hit instead would show a quarter of a pane for a move that fills half of it.
///
/// It was glass tinted with the accent. Glass over a pane bent and blurred what the pane
/// showed, a second material in a window that has one, and said nothing the wash does not.
@MainActor
final class DropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        refreshTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Under Reduce Transparency — and Increase Contrast — the wash becomes a solid
    /// high-contrast fill with a border: the states where a drop target that is merely
    /// suggested would be no target at all.
    func refreshTint() {
        // `NSColor.cgColor` is where a dynamic colour collapses, and it collapses against
        // whatever appearance is current rather than this view's.
        layer?.cornerRadius = Token.Space.paneRadius
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            if Token.Environment_.reduceTransparency || Token.Environment_.increaseContrast {
                layer?.backgroundColor = Token.Colour.accent.nsColor
                    .withAlphaComponent(0.55).cgColor
                layer?.borderWidth = 2
                layer?.borderColor = Token.Colour.accent.nsColor.cgColor
            } else {
                // The sidebar's: `SessionSidebar.dragOverlay`.
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
                layer?.borderWidth = 0
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    /// Decorative: a drag in progress must reach the canvas underneath, not this.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - The canvas as a drop destination

extension SplitCanvasView {

    /// Resolve a drag's position to a target, and show it.
    func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dragged = Self.pane(from: sender) else { return [] }
        guard let target = dropTarget(sender, dragging: dragged) else {
            clearDropHighlight()
            return []
        }
        showHighlight(for: target)
        return .move
    }

    func performDrop(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropHighlight() }
        guard let dragged = Self.pane(from: sender) else { return false }
        guard let target = dropTarget(sender, dragging: dragged) else { return false }
        store.apply(target, dragging: dragged)
        return true
    }

    /// Where a drag would land. On a computed arrangement — the Agents overview — panes
    /// only trade places: see `DropZone.swapTarget`.
    private func dropTarget(_ sender: NSDraggingInfo, dragging dragged: PaneID) -> DropTarget? {
        let point = convert(sender.draggingLocation, from: nil)
        if store.isFixedArrangement {
            return DropZone.swapTarget(at: point, frames: currentResult.frames, dragged: dragged)
        }
        return DropZone.target(at: point, frames: currentResult.frames, canvas: layoutBounds,
                               dragged: dragged)
    }

    /// The pane a drag is carrying, or nil if this drag is not ours.
    static func pane(from sender: NSDraggingInfo) -> PaneID? {
        guard let raw = sender.draggingPasteboard.string(forType: PaneDragType.pasteboard)
                ?? sender.draggingPasteboard.propertyList(forType: PaneDragType.pasteboard) as? String
        else { return nil }
        return PaneID(uuidString: raw)
    }

    private func showHighlight(for target: DropTarget) {
        guard let rect = DropZone.preview(for: target,
                                          frames: currentResult.frames,
                                          canvas: layoutBounds) else {
            clearDropHighlight()
            return
        }
        let view = dropHighlight ?? {
            let v = DropHighlightView(frame: .zero)
            addSubview(v, positioned: .above, relativeTo: nil)
            dropHighlight = v
            return v
        }()
        view.refreshTint()
        // Inset so the highlight reads as sitting INSIDE the space it describes rather than
        // covering the divider it is adjacent to.
        view.frame = rect.insetBy(dx: 3, dy: 3)
        view.isHidden = false
    }

    func clearDropHighlight() {
        dropHighlight?.isHidden = true
    }
}
