import Foundation

/// The smallest fraction a pane is allowed to hold. Guards against divide-by-zero
/// and against panes decaying to invisible slivers through repeated operations.
public let minFraction: Double = 0.02

extension LayoutNode {
    /// Restore every tree invariant. Run after every mutation.
    ///
    /// 1. Containers have >= 2 children (a 1-child container is replaced by its child).
    /// 2. Fractions match the child count, are positive, and sum to 1.
    /// 3. No container has a direct child container of the same axis — same-axis
    ///    children are flattened up, with their fractions scaled by the slot they occupied.
    ///
    /// Invariant 3 is the one that keeps the tree shallow. Without it, `split right`
    /// three times builds a right-leaning chain and every divider drag resizes a
    /// different amount of content.
    public func normalized() -> LayoutNode {
        guard case .container(var c) = self else { return self }

        var children: [LayoutNode] = []
        var fractions: [Double] = []
        children.reserveCapacity(c.children.count)
        fractions.reserveCapacity(c.children.count)

        for (i, child) in c.children.enumerated() {
            let normalizedChild = child.normalized()
            let slot = i < c.fractions.count ? c.fractions[i] : 1.0 / Double(c.children.count)

            if let inner = normalizedChild.asContainer, inner.axis == c.axis {
                // Flatten: the child's children become our children, sharing its slot.
                for (j, grandchild) in inner.children.enumerated() {
                    children.append(grandchild)
                    fractions.append(slot * inner.fractions[j])
                }
            } else {
                children.append(normalizedChild)
                fractions.append(slot)
            }
        }

        if children.count == 1 { return children[0] }

        c.children = children
        c.fractions = Self.rebalance(fractions)
        return .container(c)
    }

    /// Clamp to `minFraction` and rescale so the sum is exactly 1.
    static func rebalance(_ fractions: [Double]) -> [Double] {
        guard !fractions.isEmpty else { return [] }
        let clamped = fractions.map { $0.isFinite ? Swift.max($0, minFraction) : minFraction }
        let total = clamped.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1.0 / Double(fractions.count), count: fractions.count)
        }
        var scaled = clamped.map { $0 / total }
        // Push all accumulated floating-point error into the last slot so the sum is
        // exactly 1 and layout never leaves a sliver at the trailing edge.
        let drift = 1.0 - scaled.reduce(0, +)
        scaled[scaled.count - 1] += drift
        return scaled
    }
}

extension LayoutTree {
    public mutating func normalize() {
        root = root.normalized()
        let panes = Set(root.paneIDs)
        if !panes.contains(focused), let first = root.paneIDs.first { focused = first }
        if let z = zoomed, !panes.contains(z) { zoomed = nil }
    }

    /// Debug-build invariant check. Also used directly by property tests.
    public func validate() -> [String] {
        var problems: [String] = []
        var seen = Set<PaneID>()

        func walk(_ node: LayoutNode, depth: Int) {
            switch node {
            case .leaf(let l):
                if !seen.insert(l.paneID).inserted {
                    problems.append("duplicate paneID \(l.paneID)")
                }
            case .container(let c):
                if c.children.count < 2 {
                    problems.append("container \(c.id) has \(c.children.count) children")
                }
                if c.fractions.count != c.children.count {
                    problems.append("container \(c.id) fraction/child count mismatch")
                }
                let sum = c.fractions.reduce(0, +)
                if abs(sum - 1.0) > 1e-9 {
                    problems.append("container \(c.id) fractions sum to \(sum)")
                }
                for f in c.fractions where f <= 0 || !f.isFinite {
                    problems.append("container \(c.id) has non-positive fraction \(f)")
                }
                for child in c.children {
                    if let inner = child.asContainer, inner.axis == c.axis {
                        problems.append("container \(c.id) has same-axis child \(inner.id)")
                    }
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        if !seen.contains(focused) { problems.append("focused pane \(focused) not in tree") }
        if let z = zoomed, !seen.contains(z) { problems.append("zoomed pane \(z) not in tree") }
        return problems
    }
}
