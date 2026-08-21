import CoreGraphics

/// Direction in which a container arranges its children.
public enum Axis: String, Codable, Sendable, Hashable, CaseIterable {
    /// Children laid out left → right.
    case horizontal
    /// Children laid out top → bottom.
    case vertical

    public var perpendicular: Axis { self == .horizontal ? .vertical : .horizontal }
}

/// The side of a pane a split lands on, or the direction a focus move travels.
public enum Edge: String, Codable, Sendable, Hashable, CaseIterable {
    case left, right, top, bottom

    /// The axis a split on this edge produces.
    public var axis: Axis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// Whether the new pane is inserted before the source pane in child order.
    public var insertsBefore: Bool {
        switch self {
        case .left, .top: true
        case .right, .bottom: false
        }
    }

    public var opposite: Edge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

extension CGRect {
    /// Extent along `axis`.
    func size(along axis: Axis) -> CGFloat {
        axis == .horizontal ? width : height
    }

    /// Leading edge along `axis` — in a flipped (top-left origin) coordinate space,
    /// which is what `SplitCanvasView` uses.
    func origin(along axis: Axis) -> CGFloat {
        axis == .horizontal ? minX : minY
    }

    /// Build a rect from independent spans on each axis.
    static func spanning(_ axis: Axis, from start: CGFloat, to end: CGFloat, cross: CGRect) -> CGRect {
        switch axis {
        case .horizontal:
            CGRect(x: start, y: cross.minY, width: end - start, height: cross.height)
        case .vertical:
            CGRect(x: cross.minX, y: start, width: cross.width, height: end - start)
        }
    }
}

/// Snap a coordinate to the backing-store pixel grid.
///
/// Edges are snapped, never sizes — so adjacent panes always share an exact boundary
/// and no seam or overlap can appear between them. See docs/01-SPLIT-ENGINE.md § 3.
@inlinable
public func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    guard scale > 0 else { return value }
    return (value * scale).rounded() / scale
}
