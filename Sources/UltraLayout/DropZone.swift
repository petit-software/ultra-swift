import CoreGraphics
import Foundation

/// Where a dragged pane would land.
public enum DropTarget: Equatable, Sendable {
    /// Trade places with this pane.
    case swap(PaneID)
    /// Sit against one edge of this pane.
    case edge(PaneID, Edge)
    /// Sit against one edge of the WHOLE canvas, splitting the root.
    ///
    /// The case the five per-pane zones cannot express: "down the entire left side", not
    /// "to the left of that one pane". Without it a full-height sidebar can only be built
    /// by starting over, because every drop lands inside some existing pane and inherits
    /// its height.
    case root(Edge)
}

/// Hit-testing for pane drag-and-drop. Pure geometry — no views, no window.
public enum DropZone {

    /// How far into the canvas the root band reaches.
    ///
    /// Measured from the canvas edge, and deliberately generous: it has to be hittable while
    /// the pointer is also carrying a drag image, and the gutter between panes and the window
    /// edge is only a few points wide. It is small enough that the middle of any pane still
    /// belongs to that pane.
    public static let rootBandInset: CGFloat = 28

    /// The share of a pane, centred, that means "swap" rather than "move to an edge".
    public static let swapFraction: CGFloat = 0.4

    /// What a drop at `point` would do.
    ///
    /// - Parameters:
    ///   - frames: every visible pane's frame, in the same space as `point` and `canvas`.
    ///   - canvas: the padded content rect the panes tile.
    ///   - dragged: the pane being moved, so it can refuse to land on itself.
    public static func target(at point: CGPoint,
                              frames: [PaneID: CGRect],
                              canvas: CGRect,
                              dragged: PaneID) -> DropTarget? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        // The root band is checked FIRST, and outside the panes as well as just inside them.
        // A drop in the margin has no pane under it at all, and one just inside the outermost
        // pane must still mean "the whole side" — otherwise the gesture would only work in a
        // gutter a few points wide, which is not a target anyone can hit.
        if let edge = rootEdge(at: point, canvas: canvas) {
            // Splitting the root around the only pane there is would be a no-op dressed as a
            // move, so it is refused rather than silently doing nothing.
            return frames.count > 1 ? .root(edge) : nil
        }

        guard let (paneID, frame) = frames.first(where: { $0.value.contains(point) }),
              paneID != dragged                      // dropping a pane on itself does nothing
        else { return nil }

        let inset = CGSize(width: frame.width * (1 - swapFraction) / 2,
                           height: frame.height * (1 - swapFraction) / 2)
        if frame.insetBy(dx: inset.width, dy: inset.height).contains(point) {
            return .swap(paneID)
        }
        return .edge(paneID, nearestEdge(of: frame, to: point))
    }

    /// Which outer edge, if the point is in the canvas's margin band.
    ///
    /// A point in a corner belongs to whichever band it is deeper into, so the two bands
    /// meet on the corner's diagonal instead of one of them winning by declaration order.
    public static func rootEdge(at point: CGPoint, canvas: CGRect) -> Edge? {
        let band = min(rootBandInset, min(canvas.width, canvas.height) / 4)
        let depths: [(Edge, CGFloat)] = [
            (.left, point.x - canvas.minX),
            (.right, canvas.maxX - point.x),
            (.top, point.y - canvas.minY),
            (.bottom, canvas.maxY - point.y),
        ]
        // Outside the canvas entirely still counts: a drag released past the window's content
        // reads as "put it on that side", and refusing it would make the gesture feel broken
        // exactly at the edge people aim for.
        guard let nearest = depths.min(by: { $0.1 < $1.1 }) else { return nil }
        return nearest.1 < band ? nearest.0 : nil
    }

    /// The nearest side of a rect, measured in NORMALISED units — which is exactly the
    /// rect's diagonals, the rule window snapping already taught everyone.
    ///
    /// Physical distance would let a wide pane's short top band swallow most of its left
    /// band, so a point 40pt from the left edge of a 1200pt-wide pane would read as "top".
    public static func nearestEdge(of frame: CGRect, to point: CGPoint) -> Edge {
        let x = (point.x - frame.minX) / max(frame.width, 1)
        let y = (point.y - frame.minY) / max(frame.height, 1)
        let distances: [(Edge, CGFloat)] = [
            (.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y),
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .left
    }

    /// The rect to highlight for a target — what the pane will actually occupy if dropped.
    ///
    /// A preview of the RESULT, not of the zone that was hit. Highlighting the zone would
    /// show a quarter of a pane for a move that fills half of it.
    public static func preview(for target: DropTarget,
                               frames: [PaneID: CGRect],
                               canvas: CGRect) -> CGRect? {
        switch target {
        case .swap(let paneID):
            return frames[paneID]
        case .edge(let paneID, let edge):
            guard let frame = frames[paneID] else { return nil }
            return half(of: frame, on: edge)
        case .root(let edge):
            return half(of: canvas, on: edge)
        }
    }

    private static func half(of rect: CGRect, on edge: Edge) -> CGRect {
        switch edge {
        case .left:   CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:  CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top:    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}
