import CoreGraphics
import Foundation

/// Remembers where a directional move came from, so ←→←→ round-trips instead of drifting.
public struct NavigationMemory: Sendable, Equatable {
    private var entries: [PaneID: [Edge: PaneID]] = [:]

    public init() {}

    public mutating func record(from source: PaneID, to destination: PaneID, edge: Edge) {
        entries[destination, default: [:]][edge.opposite] = source
    }

    public func remembered(from pane: PaneID, edge: Edge) -> PaneID? {
        entries[pane]?[edge]
    }

    public mutating func forget(_ paneID: PaneID) {
        entries.removeValue(forKey: paneID)
        for key in entries.keys {
            entries[key] = entries[key]?.filter { $0.value != paneID }
        }
    }
}

/// Spatial focus movement.
///
/// Tree-order navigation in a grid sends you somewhere unrelated and is the single most
/// common complaint about split panes, so this works purely from geometry.
///
/// 1. Candidates lie strictly on the `direction` side of the source.
/// 2. Prefer candidates whose perpendicular projection overlaps the source; among those,
///    the smallest gap, then the largest overlap.
/// 3. Otherwise the nearest centre.
/// 4. No wrap-around — wrapping in a spatial layout is disorienting.
public func focusTarget(from paneID: PaneID,
                        direction: Edge,
                        frames: [PaneID: CGRect],
                        memory: NavigationMemory? = nil) -> PaneID? {
    guard let source = frames[paneID] else { return nil }

    let candidates = frames.filter { id, frame in
        guard id != paneID else { return false }
        return switch direction {
        case .right: frame.minX >= source.maxX - 1
        case .left: frame.maxX <= source.minX + 1
        case .bottom: frame.minY >= source.maxY - 1
        case .top: frame.maxY <= source.minY + 1
        }
    }
    guard !candidates.isEmpty else { return nil }

    // A remembered target still wins, but only if it is a legitimate candidate.
    if let remembered = memory?.remembered(from: paneID, edge: direction),
       candidates.keys.contains(remembered) {
        return remembered
    }

    let axis = direction.axis
    func gap(_ frame: CGRect) -> CGFloat {
        switch direction {
        case .right: frame.minX - source.maxX
        case .left: source.minX - frame.maxX
        case .bottom: frame.minY - source.maxY
        case .top: source.minY - frame.maxY
        }
    }
    func overlap(_ frame: CGRect) -> CGFloat {
        switch axis {
        case .horizontal: min(frame.maxY, source.maxY) - max(frame.minY, source.minY)
        case .vertical: min(frame.maxX, source.maxX) - max(frame.minX, source.minX)
        }
    }

    let overlapping = candidates.filter { overlap($0.value) > 0 }
    if !overlapping.isEmpty {
        return overlapping.min { a, b in
            let (ga, gb) = (gap(a.value), gap(b.value))
            if abs(ga - gb) > 1 { return ga < gb }
            let (oa, ob) = (overlap(a.value), overlap(b.value))
            if abs(oa - ob) > 1 { return oa > ob }
            return a.key.uuidString < b.key.uuidString
        }?.key
    }

    func distance(_ frame: CGRect) -> CGFloat {
        let dx = frame.midX - source.midX, dy = frame.midY - source.midY
        return dx * dx + dy * dy
    }
    return candidates.min { distance($0.value) < distance($1.value) }?.key
}

extension LayoutTree {
    /// The divider a keyboard resize should move: the one on `edge` of the focused pane.
    /// ⌃⌘→ grows the focused pane to the right by moving the divider on its right edge.
    public func nearestDivider(to paneID: PaneID, edge: Edge, in result: LayoutResult) -> DividerFrame? {
        guard let frame = result.frames[paneID] else { return nil }
        let wanted = result.dividers.filter { $0.axis == edge.axis }
        return wanted.min { a, b in
            func score(_ d: DividerFrame) -> CGFloat {
                switch edge {
                case .right: abs(d.lineRect.minX - frame.maxX)
                case .left: abs(d.lineRect.maxX - frame.minX)
                case .bottom: abs(d.lineRect.minY - frame.maxY)
                case .top: abs(d.lineRect.maxY - frame.minY)
                }
            }
            return score(a) < score(b)
        }
    }
}
