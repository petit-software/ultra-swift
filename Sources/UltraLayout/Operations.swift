import CoreGraphics
import Foundation

/// How a divider behaves when an adjacent pane reaches its minimum size.
public enum ResizeMode: Sendable {
    /// The divider stops. Cascading into the next divider feels like the layout is
    /// sliding out from under you, so this is the default.
    case hardStop
    /// Consume slack from successive siblings. Opt-in, via ⌥-drag.
    case push
}

/// Identifies the boundary between children `index` and `index + 1` of a container.
public struct DividerRef: Hashable, Sendable, Codable {
    public let containerID: NodeID
    public let index: Int

    public init(containerID: NodeID, index: Int) {
        self.containerID = containerID
        self.index = index
    }
}

extension LayoutTree {

    // MARK: - Split

    /// Split `paneID`, putting `newPane` on `edge` of it.
    ///
    /// The new pane's space is taken **only from the source pane**. Every other sibling
    /// keeps its exact size. Re-equalizing all siblings on every split is the most common
    /// way a split engine feels wrong: it destroys a carefully sized layout the moment the
    /// user splits a fourth pane off one of them.
    @discardableResult
    public mutating func split(_ paneID: PaneID,
                               edge: Edge,
                               newPane: PaneID,
                               ratio: Double = 0.5) -> Bool {
        guard !contains(newPane), let path = root.path(toPane: paneID) else { return false }
        let ratio = min(max(ratio, minFraction), 1 - minFraction)
        let newLeaf = LayoutNode.leaf(Leaf(paneID: newPane, spaceFrom: paneID))

        if path.isEmpty {
            // Root is the pane itself: the root becomes a container.
            root = .container(Container(
                axis: edge.axis,
                children: edge.insertsBefore ? [newLeaf, root] : [root, newLeaf],
                fractions: edge.insertsBefore ? [ratio, 1 - ratio] : [1 - ratio, ratio]))
        } else {
            let parentPath = Array(path.dropLast())
            let index = path[path.count - 1]

            if var parent = root[parentPath].asContainer, parent.axis == edge.axis {
                // Same axis: insert a sibling and take space only from the source.
                let slot = parent.fractions[index]
                let insertAt = edge.insertsBefore ? index : index + 1
                parent.fractions[index] = slot * (1 - ratio)
                parent.children.insert(newLeaf, at: insertAt)
                parent.fractions.insert(slot * ratio, at: insertAt)
                root[parentPath] = .container(parent)
            } else {
                // Perpendicular axis: wrap the leaf in a new container in place.
                let existing = root[path]
                root[path] = .container(Container(
                    axis: edge.axis,
                    children: edge.insertsBefore ? [newLeaf, existing] : [existing, newLeaf],
                    fractions: edge.insertsBefore ? [ratio, 1 - ratio] : [1 - ratio, ratio]))
            }
        }

        focused = newPane
        zoomed = nil
        normalize()
        return true
    }

    // MARK: - Close

    /// Remove a pane. Its space is distributed to the remaining siblings
    /// **proportionally**, so their relative sizes survive.
    @discardableResult
    public mutating func close(_ paneID: PaneID) -> Bool {
        guard let path = root.path(toPane: paneID), !path.isEmpty else {
            return false  // never close the last pane; the window closes instead
        }

        let parentPath = Array(path.dropLast())
        let index = path[path.count - 1]
        guard var parent = root[parentPath].asContainer else { return false }
        let closing = root[path].asLeaf

        // Choose the next focus before the tree changes under us.
        let neighbourIndex = index == parent.children.count - 1 ? index - 1 : index + 1
        let nextFocus = parent.children[neighbourIndex].paneIDs.first

        parent.children.remove(at: index)
        let freed = parent.fractions.remove(at: index)

        if parent.children.count == 1 {
            // Splice the survivor into the grandparent's slot. The fraction belongs to
            // the slot, not the node, so nothing else needs adjusting.
            root[parentPath] = parent.children[0]
        } else {
            if let origin = closing?.spaceFrom,
               let heir = parent.children.firstIndex(where: { $0.paneIDs.contains(origin) }) {
                // Give the space back where it came from, so the other siblings do not move.
                parent.fractions[heir] += freed
            } else {
                // No provenance (a restored or moved pane): share it out proportionally,
                // which at least preserves the survivors' relative sizes.
                let total = parent.fractions.reduce(0, +)
                if total > 0 { parent.fractions = parent.fractions.map { $0 / total } }
            }
            parent.fractions = LayoutNode.rebalance(parent.fractions)
            root[parentPath] = .container(parent)
        }

        if focused == paneID, let nextFocus { focused = nextFocus }
        if zoomed == paneID { zoomed = nil }
        normalize()
        return true
    }

    // MARK: - Resize

    /// Move one divider. Only the two adjacent children change — unless `mode` is `.push`.
    ///
    /// - Parameters:
    ///   - containerSize: space available to the children along the axis, i.e. after
    ///     gutters have been subtracted.
    ///   - minPaneSize: minimum extent of a pane along that axis, in points.
    /// - Returns: the delta actually applied, in points, so a drag handler can keep the
    ///   divider glued to the cursor instead of letting the cursor drift away from a
    ///   divider that has stopped.
    @discardableResult
    public mutating func resize(divider: DividerRef,
                                by delta: CGFloat,
                                containerSize: CGFloat,
                                minPaneSize: CGFloat,
                                mode: ResizeMode = .hardStop) -> CGFloat {
        guard containerSize > 0, delta != 0,
              let path = root.path(toNode: divider.containerID),
              var container = root[path].asContainer,
              container.fractions.indices.contains(divider.index),
              container.fractions.indices.contains(divider.index + 1)
        else { return 0 }

        let minF = max(Double(minPaneSize / containerSize), minFraction)
        let i = divider.index
        let n = container.fractions.count
        var f = container.fractions
        let requested = Double(delta / containerSize)
        let applied: Double

        if requested > 0 {
            let donors = mode == .hardStop ? [i + 1] : Array((i + 1)..<n)
            let donated = Self.donate(&f, amount: requested, from: donors, minF: minF)
            f[i] += donated
            applied = donated
        } else {
            let donors = mode == .hardStop ? [i] : Array((0...i).reversed())
            let donated = Self.donate(&f, amount: -requested, from: donors, minF: minF)
            f[i + 1] += donated
            applied = -donated
        }

        container.fractions = Self.fixDrift(f)
        root[path] = .container(container)
        return CGFloat(applied) * containerSize
    }

    /// Take `amount` from `indices` in order, never dropping any below `minF`.
    /// Returns how much was actually taken.
    private static func donate(_ f: inout [Double], amount: Double, from indices: [Int], minF: Double) -> Double {
        var need = amount
        for j in indices {
            guard need > 1e-12 else { break }
            let available = max(0, f[j] - minF)
            let take = min(available, need)
            f[j] -= take
            need -= take
        }
        return amount - need
    }

    /// Push accumulated floating-point error into the largest slot, where it is invisible.
    private static func fixDrift(_ f: [Double]) -> [Double] {
        var f = f
        let drift = 1.0 - f.reduce(0, +)
        if abs(drift) > 0, let largest = f.indices.max(by: { f[$0] < f[$1] }) {
            f[largest] += drift
        }
        return f
    }

    // MARK: - Equalize / zoom / swap / move

    /// Give every child of one container the same fraction. ⌘= and double-clicking a divider.
    @discardableResult
    public mutating func equalize(container containerID: NodeID) -> Bool {
        guard let path = root.path(toNode: containerID),
              var container = root[path].asContainer else { return false }
        container.fractions = Array(repeating: 1.0 / Double(container.children.count),
                                    count: container.children.count)
        root[path] = .container(container)
        return true
    }

    public mutating func equalizeAll() {
        func walk(_ node: LayoutNode) -> LayoutNode {
            guard var c = node.asContainer else { return node }
            c.children = c.children.map(walk)
            c.fractions = Array(repeating: 1.0 / Double(c.children.count), count: c.children.count)
            return .container(c)
        }
        root = walk(root)
    }

    /// Non-destructive maximize: sets a field the layout function reads. Un-zooming
    /// restores the exact previous geometry because that geometry was never modified.
    public mutating func toggleZoom(_ paneID: PaneID) {
        guard contains(paneID) else { return }
        zoomed = (zoomed == paneID) ? nil : paneID
    }

    /// Exchange the positions of two panes.
    @discardableResult
    public mutating func swap(_ a: PaneID, _ b: PaneID) -> Bool {
        guard a != b,
              let pathA = root.path(toPane: a),
              let pathB = root.path(toPane: b),
              var leafA = root[pathA].asLeaf,
              var leafB = root[pathB].asLeaf else { return false }
        // Provenance describes where a pane's space came from; after a swap it is a lie.
        leafA.paneID = b
        leafA.spaceFrom = nil
        leafB.paneID = a
        leafB.spaceFrom = nil
        root[pathA] = .leaf(leafA)
        root[pathB] = .leaf(leafB)
        return true
    }

    /// Move a pane to an edge of another pane. Atomic: close then split, or nothing.
    @discardableResult
    public mutating func move(_ paneID: PaneID, toEdgeOf target: PaneID, edge: Edge) -> Bool {
        guard paneID != target, contains(paneID), contains(target), paneCount >= 2 else { return false }
        var candidate = self
        guard candidate.close(paneID), candidate.contains(target),
              candidate.split(target, edge: edge, newPane: paneID) else { return false }
        candidate.focused = paneID
        self = candidate
        return true
    }

    /// Move a pane to one edge of the WHOLE tree, spanning that entire side.
    ///
    /// The operation `move(_:toEdgeOf:edge:)` cannot express. That one splits a target pane,
    /// so the moved pane inherits the target's height or width — a "sidebar" built that way
    /// is only as tall as whichever pane it landed beside. This wraps the root instead, so
    /// the pane runs the full side and everything else compresses into the remainder.
    ///
    /// Built the same way as its sibling: close, then rebuild. Closing first is what keeps
    /// the pane count honest and lets `close` collapse whatever container the pane leaves
    /// behind — moving a node without removing it first is how a tree grows a container with
    /// one child.
    public mutating func move(_ paneID: PaneID, toRootEdge edge: Edge) -> Bool {
        guard contains(paneID), paneCount >= 2 else { return false }
        var candidate = self
        guard candidate.close(paneID) else { return false }

        let moved = LayoutNode.leaf(Leaf(paneID: paneID))
        // Leading edges put the pane FIRST in the container; trailing edges put it last.
        // The axis follows the edge, so a left or right drop makes a horizontal split.
        let children = (edge == .left || edge == .top)
            ? [moved, candidate.root]
            : [candidate.root, moved]
        candidate.root = .container(Container(id: UUID(), axis: edge.axis, children: children))
        candidate.focused = paneID
        candidate.normalize()
        guard candidate.validate().isEmpty else { return false }
        self = candidate
        return true
    }
}
