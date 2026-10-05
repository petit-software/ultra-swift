import CoreGraphics

/// The arithmetic of dragging one tab along a row of tabs of different widths.
///
/// Pure, so a reorder is decided by numbers a test can check rather than by what a drop
/// delegate happened to be told. The view measures the tabs, feeds the dragged tab's
/// position in, and draws what comes back: where the tab would land, how far each other
/// tab slides to make room, and where the empty slot sits.
///
/// Positions are in the strip's CONTENT coordinates: `leading` is the inset before the
/// first tab, and each tab follows the last with `spacing` between.
public struct TabStripReorder: Equatable, Sendable {
    public let widths: [CGFloat]
    public let spacing: CGFloat
    public let leading: CGFloat

    public init(widths: [CGFloat], spacing: CGFloat, leading: CGFloat) {
        self.widths = widths
        self.spacing = spacing
        self.leading = leading
    }

    /// Where tab `index` starts, with nothing being dragged.
    public func minX(of index: Int) -> CGFloat {
        leading + widths[..<index].reduce(0, +) + spacing * CGFloat(index)
    }

    /// The whole strip, insets on both ends included.
    public var contentWidth: CGFloat {
        guard !widths.isEmpty else { return leading * 2 }
        return leading * 2 + widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
    }

    /// Keeps the dragged tab inside the strip, so it cannot be pulled off either end.
    public func clampedMinX(_ x: CGFloat, dragging from: Int) -> CGFloat {
        let upper = max(leading, contentWidth - leading - widths[from])
        return min(max(x, leading), upper)
    }

    /// The index the dragged tab lands at when its leading edge is at `x`: the number of
    /// OTHER tabs whose middle it has passed. Measured against where the others started,
    /// not where they have slid to, so the answer cannot flicker as they move.
    public func destination(dragging from: Int, minX x: CGFloat) -> Int {
        let centre = x + widths[from] / 2
        return widths.indices.reduce(0) { count, index in
            guard index != from else { return count }
            return minX(of: index) + widths[index] / 2 < centre ? count + 1 : count
        }
    }

    /// What letting go of a dragged tab means.
    public enum Release: Equatable, Sendable {
        /// It lands at this index, which is not where it started.
        case move(to: Int)
        /// It is back where it started, so nothing was reordered: the press was a click.
        case select
        /// Let go away from the strip: the tab goes back and nothing else happens.
        case cancel
    }

    /// What a drag that ends with the tab's leading edge at `x` amounts to.
    ///
    /// `select` is the case that matters. A press becomes a drag after a few points of
    /// travel, which a hurried click covers between button down and button up — and from
    /// then on it is a drag's release, not a click, that the strip hears. A drag that moved
    /// nothing has to count as the click it was, or a tab pressed in passing does nothing
    /// at all: no reorder, and no selection either.
    public func release(dragging from: Int, minX x: CGFloat, onStrip: Bool) -> Release {
        guard onStrip else { return .cancel }
        let to = destination(dragging: from, minX: x)
        return to == from ? .select : .move(to: to)
    }

    /// How far tab `index` — not the dragged one — slides to open the gap at `to`.
    public func shift(of index: Int, dragging from: Int, to: Int) -> CGFloat {
        let room = widths[from] + spacing
        if from < to, index > from, index <= to { return -room }
        if to < from, index >= to, index < from { return room }
        return 0
    }

    /// How far the empty slot sits from the dragged tab's starting place.
    public func slotOffset(dragging from: Int, to: Int) -> CGFloat {
        if to > from { return (from + 1...to).reduce(0) { $0 + widths[$1] + spacing } }
        if to < from { return -(to..<from).reduce(0) { $0 + widths[$1] + spacing } }
        return 0
    }

    /// `destination` as the `toOffset` of `Array.move(fromOffsets:toOffset:)`, which counts
    /// positions BEFORE the move — one past the target when moving right.
    public static func moveOffset(from: Int, to: Int) -> Int { to > from ? to + 1 : to }

    /// -1, 0 or 1: whether a pointer at `x` in a viewport `width` wide is close enough to
    /// an edge to scroll the strip that way.
    public static func autoscrollDirection(pointerX x: CGFloat, viewportWidth width: CGFloat,
                                           edge: CGFloat) -> Int {
        if x < edge { return -1 }
        if x > width - edge { return 1 }
        return 0
    }
}
