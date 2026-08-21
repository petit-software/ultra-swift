import CoreGraphics
import Foundation

public struct LayoutMetrics: Equatable, Sendable {
    /// Space between siblings. The divider hairline is drawn centered in it.
    public var gutter: CGFloat
    /// Inset around the whole canvas.
    public var padding: CGFloat
    /// Extra inset on the LEADING, TRAILING and BOTTOM edges only. The top is left alone:
    /// the toolbar's content layout rect already holds the panes off that edge, so adding
    /// it there too would read as a double gap under the toolbar.
    public var edgeInset: CGFloat
    public var minPaneSize: CGSize
    /// Hit area for a divider — allowed to exceed the gutter and overlap the panes.
    /// Users aim at the visible line; they should not have to be precise.
    public var dividerHitWidth: CGFloat
    public var dividerLineWidth: CGFloat
    /// Backing-store scale, for pixel snapping.
    public var scale: CGFloat

    public init(gutter: CGFloat = 12,
                padding: CGFloat = 8,
                edgeInset: CGFloat = 4,
                minPaneSize: CGSize = CGSize(width: 160, height: 80),
                dividerHitWidth: CGFloat = 16,
                dividerLineWidth: CGFloat = 1,
                scale: CGFloat = 2) {
        self.gutter = gutter
        self.padding = padding
        self.edgeInset = edgeInset
        self.minPaneSize = minPaneSize
        self.dividerHitWidth = dividerHitWidth
        self.dividerLineWidth = dividerLineWidth
        self.scale = scale
    }

    public static let `default` = LayoutMetrics()

    /// The rect the panes actually tile: `padding` on every edge, plus `edgeInset` on the
    /// leading, trailing and bottom edges. The single definition of "the padded canvas" —
    /// the layout engine lays out into it and the coverage invariants assert against it.
    public func contentRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + padding + edgeInset,
               y: bounds.minY + padding,
               width: max(0, bounds.width - 2 * (padding + edgeInset)),
               height: max(0, bounds.height - 2 * padding - edgeInset))
    }
}

public struct DividerFrame: Equatable, Sendable {
    public let ref: DividerRef
    public let axis: Axis
    /// Generous target for the pointer.
    public let hitRect: CGRect
    /// The 1pt hairline actually drawn.
    public let lineRect: CGRect
    /// Cumulative fraction at this boundary — the AX splitter value.
    public let fraction: Double
    /// Space available to the container's children along the axis, after gutters.
    /// A drag handler needs this to convert points into a fraction delta.
    public let containerSize: CGFloat

    public init(ref: DividerRef, axis: Axis, hitRect: CGRect, lineRect: CGRect,
                fraction: Double, containerSize: CGFloat) {
        self.ref = ref
        self.axis = axis
        self.hitRect = hitRect
        self.lineRect = lineRect
        self.fraction = fraction
        self.containerSize = containerSize
    }
}

public struct LayoutResult: Equatable, Sendable {
    public var frames: [PaneID: CGRect] = [:]
    public var dividers: [DividerFrame] = []
    /// Non-empty only while a pane is zoomed.
    public var hidden: Set<PaneID> = []

    public init() {}

    /// Panes in reading order — top to bottom, then left to right. This is the order
    /// ⌘1…⌘9 use: the number the user counts on screen is the number they press.
    public var visualOrder: [PaneID] {
        frames.sorted { a, b in
            if abs(a.value.minY - b.value.minY) > 1 { return a.value.minY < b.value.minY }
            if abs(a.value.minX - b.value.minX) > 1 { return a.value.minX < b.value.minX }
            return a.key.uuidString < b.key.uuidString
        }.map(\.key)
    }

    /// The divider under a point.
    ///
    /// A vertical and a horizontal divider necessarily overlap where they cross, so hit
    /// areas alone are ambiguous at a junction. Resolve by the nearest drawn hairline —
    /// deterministic, and it matches what the user was aiming at.
    public func divider(at point: CGPoint) -> DividerFrame? {
        let candidates = dividers.filter { $0.hitRect.contains(point) }
        guard candidates.count > 1 else { return candidates.first }
        return candidates.min { distanceSquared(from: point, to: $0.lineRect)
                              < distanceSquared(from: point, to: $1.lineRect) }
    }

    public func pane(at point: CGPoint) -> PaneID? {
        frames.first { $0.value.contains(point) && !hidden.contains($0.key) }?.key
    }
}

/// Project a tree onto a rectangle. Pure, synchronous, and cheap enough to call on
/// every live-resize frame — do not add a cache before measuring.
public func layout(_ tree: LayoutTree,
                   in bounds: CGRect,
                   metrics: LayoutMetrics = .default) -> LayoutResult {
    var result = LayoutResult()
    // Snap the canvas once, here. Children then snap only along their own axis and
    // inherit an already-snapped cross axis, so every edge in the tree lands on the
    // pixel grid without re-snapping at every level.
    let content = metrics.contentRect(in: bounds)
        .snapped(to: metrics.scale)
    guard content.width > 0, content.height > 0 else { return result }

    if let zoomed = tree.zoomed, tree.contains(zoomed) {
        result.frames[zoomed] = content
        result.hidden = Set(tree.paneIDs).subtracting([zoomed])
        return result
    }

    place(tree.root, in: content, metrics: metrics, into: &result)
    return result
}

private func place(_ node: LayoutNode,
                   in rect: CGRect,
                   metrics: LayoutMetrics,
                   into result: inout LayoutResult) {
    switch node {
    case .leaf(let leaf):
        result.frames[leaf.paneID] = rect

    case .container(let container):
        let axis = container.axis
        let count = container.children.count
        let scale = metrics.scale
        let total = rect.size(along: axis)
        let origin = rect.origin(along: axis)
        // Subtract gutters BEFORE distributing. Distributing over the full size and
        // insetting afterwards accumulates drift.
        let available = max(0, total - metrics.gutter * CGFloat(count - 1))

        // `rawCursor` tracks the unsnapped position so snapping never accumulates error;
        // `start` is the snapped edge the current child actually begins at.
        var rawCursor = origin
        var start = snap(origin, scale: scale)

        for index in 0..<count {
            let rawEnd = rawCursor + available * CGFloat(container.fractions[index])
            // The last child's trailing edge is pinned to the container's, so children
            // tile the container exactly and the last pane is never a pixel short.
            let end = index == count - 1
                ? snap(origin + total, scale: scale)
                : snap(rawEnd, scale: scale)

            place(container.children[index],
                  in: .spanning(axis, from: start, to: max(start, end), cross: rect),
                  metrics: metrics,
                  into: &result)

            guard index < count - 1 else { break }

            let gutterEnd = snap(end + metrics.gutter, scale: scale)
            let lineInset = (metrics.gutter - metrics.dividerLineWidth) / 2
            // Clamped at 0: once the gutter grew past `dividerHitWidth` this went negative,
            // which pulled the grab area INSIDE the gutter instead of over the panes.
            let hitInset = max(0, (metrics.dividerHitWidth - metrics.gutter) / 2)

            result.dividers.append(DividerFrame(
                ref: DividerRef(containerID: container.id, index: index),
                axis: axis,
                hitRect: .spanning(axis, from: end - hitInset, to: gutterEnd + hitInset, cross: rect),
                lineRect: .spanning(axis,
                                    from: end + lineInset,
                                    to: end + lineInset + metrics.dividerLineWidth,
                                    cross: rect),
                fraction: container.fractions[0...index].reduce(0, +),
                containerSize: available))

            rawCursor = rawEnd + metrics.gutter
            start = gutterEnd
        }
    }
}

/// Whether a split would leave both halves usable. A split that produces a 20pt pane
/// is refused with a UI nudge rather than silently made.
public func canSplit(_ tree: LayoutTree,
                     pane: PaneID,
                     edge: Edge,
                     in bounds: CGRect,
                     metrics: LayoutMetrics = .default,
                     ratio: Double = 0.5) -> Bool {
    guard let frame = layout(tree, in: bounds, metrics: metrics).frames[pane] else { return false }
    let usable = frame.size(along: edge.axis) - metrics.gutter
    guard usable > 0 else { return false }
    let minimum = metrics.minPaneSize.size(along: edge.axis)
    return usable * CGFloat(ratio) >= minimum && usable * CGFloat(1 - ratio) >= minimum
}

/// Zero when the point is inside the rect.
func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return dx * dx + dy * dy
}

extension CGSize {
    public func size(along axis: Axis) -> CGFloat { axis == .horizontal ? width : height }
}

extension CGRect {
    /// Snap all four edges — never the size — so adjacent rects share exact boundaries.
    func snapped(to scale: CGFloat) -> CGRect {
        let x0 = snap(minX, scale: scale), y0 = snap(minY, scale: scale)
        let x1 = snap(maxX, scale: scale), y1 = snap(maxY, scale: scale)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
