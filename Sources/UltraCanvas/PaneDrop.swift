import AppKit
import UltraDesign
import UltraLayout

/// The highlight shown while a pane is being dragged.
///
/// Glass tinted with the accent, sized to where the pane will ACTUALLY land — a half for an
/// edge, the whole pane for a swap, a full side for a root split. Previewing the zone that
/// was hit instead would show a quarter of a pane for a move that fills half of it.
@MainActor
final class DropHighlightView: NSView {
    private let glass = NSGlassEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(glass)
        glass.cornerRadius = Token.Space.paneRadius
        refreshTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Under Reduce Transparency the material is dropped rather than quietly kept, so the
    /// highlight becomes a solid high-contrast fill instead of disappearing — the one state
    /// where a drop target that is merely suggested would be no target at all.
    func refreshTint() {
        if Token.Environment_.reduceTransparency {
            glass.isHidden = true
            layer?.backgroundColor = Token.Colour.accent.nsColor.withAlphaComponent(0.55).cgColor
            layer?.cornerRadius = Token.Space.paneRadius
            layer?.borderWidth = 2
            layer?.borderColor = Token.Colour.accent.nsColor.cgColor
        } else {
            glass.isHidden = false
            glass.tintColor = Token.Colour.accent.nsColor.withAlphaComponent(0.28)
        }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
    }

    /// Decorative: a drag in progress must reach the canvas underneath, not this.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - The canvas as a drop destination

extension SplitCanvasView {

    /// Resolve a drag's position to a target, and show it.
    func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dragged = Self.pane(from: sender) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        guard let target = DropZone.target(at: point,
                                           frames: currentResult.frames,
                                           canvas: layoutBounds,
                                           dragged: dragged) else {
            clearDropHighlight()
            return []
        }
        showHighlight(for: target)
        return .move
    }

    func performDrop(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropHighlight() }
        guard let dragged = Self.pane(from: sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        guard let target = DropZone.target(at: point,
                                           frames: currentResult.frames,
                                           canvas: layoutBounds,
                                           dragged: dragged) else { return false }
        store.apply(target, dragging: dragged)
        return true
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
