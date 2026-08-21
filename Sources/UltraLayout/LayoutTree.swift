import CoreGraphics
import Foundation

public typealias PaneID = UUID
public typealias NodeID = UUID

/// A pane: the leaf of the layout tree. Holds no content — content lives in the
/// pane store, keyed by `paneID`, and outlives every layout change.
public struct Leaf: Codable, Equatable, Sendable, Identifiable {
    public let id: NodeID
    public var paneID: PaneID
    /// The pane this one took its space from when it was created by a split.
    ///
    /// Closing a pane returns its space to this pane if it is still a sibling, which
    /// makes split-then-close an exact inverse: change your mind about a split and the
    /// rest of the layout is untouched. Without it, `split` takes space from one pane
    /// but `close` hands it back to all of them, so the layout drifts.
    public var spaceFrom: PaneID?

    public init(id: NodeID = UUID(), paneID: PaneID, spaceFrom: PaneID? = nil) {
        self.id = id
        self.paneID = paneID
        self.spaceFrom = spaceFrom
    }
}

/// A row or column of children.
///
/// N-ary, not binary: three panes side by side are ONE container with three
/// children. With a binary tree the middle divider of a 3-across layout resizes a
/// subtree, so panes move at different speeds depending on insertion order.
public struct Container: Codable, Equatable, Sendable, Identifiable {
    public let id: NodeID
    public var axis: Axis
    /// Invariant: at least 2 children.
    public var children: [LayoutNode]
    /// Invariant: same count as `children`, each > 0, sums to 1.
    public var fractions: [Double]

    public init(id: NodeID = UUID(), axis: Axis, children: [LayoutNode], fractions: [Double]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        self.fractions = fractions ?? Array(repeating: 1.0 / Double(max(children.count, 1)),
                                            count: children.count)
    }
}

public indirect enum LayoutNode: Codable, Equatable, Sendable, Identifiable {
    case leaf(Leaf)
    case container(Container)

    public var id: NodeID {
        switch self {
        case .leaf(let l): l.id
        case .container(let c): c.id
        }
    }

    public var asContainer: Container? {
        if case .container(let c) = self { return c }
        return nil
    }

    public var asLeaf: Leaf? {
        if case .leaf(let l) = self { return l }
        return nil
    }

    public static func pane(_ paneID: PaneID) -> LayoutNode { .leaf(Leaf(paneID: paneID)) }
}

/// The whole layout of one canvas.
public struct LayoutTree: Codable, Equatable, Sendable {
    public var root: LayoutNode
    /// The pane that receives keystrokes. Never geometry — changing focus never moves a pane.
    public var focused: PaneID
    /// Non-destructive maximize. The tree is untouched, so un-zooming restores the exact
    /// previous geometry because that geometry was never modified.
    public var zoomed: PaneID?

    public init(root: LayoutNode, focused: PaneID, zoomed: PaneID? = nil) {
        self.root = root
        self.focused = focused
        self.zoomed = zoomed
    }

    /// A tree with a single pane.
    public init(single paneID: PaneID) {
        self.init(root: .pane(paneID), focused: paneID)
    }
}

// MARK: - Traversal

extension LayoutNode {
    /// Every pane in this subtree, in child order (depth-first).
    public var paneIDs: [PaneID] {
        switch self {
        case .leaf(let l): [l.paneID]
        case .container(let c): c.children.flatMap(\.paneIDs)
        }
    }

    /// Index path from this node down to the leaf holding `paneID`, or nil if absent.
    public func path(toPane paneID: PaneID) -> [Int]? {
        switch self {
        case .leaf(let l):
            return l.paneID == paneID ? [] : nil
        case .container(let c):
            for (i, child) in c.children.enumerated() {
                if let sub = child.path(toPane: paneID) { return [i] + sub }
            }
            return nil
        }
    }

    /// Index path from this node down to the node with `nodeID`, or nil if absent.
    public func path(toNode nodeID: NodeID) -> [Int]? {
        if id == nodeID { return [] }
        guard case .container(let c) = self else { return nil }
        for (i, child) in c.children.enumerated() {
            if let sub = child.path(toNode: nodeID) { return [i] + sub }
        }
        return nil
    }

    /// Read/write access to a descendant by index path. Writing preserves value
    /// semantics all the way up — this is how every mutation in Operations.swift works.
    public subscript(path: ArraySlice<Int>) -> LayoutNode {
        get {
            guard let i = path.first else { return self }
            guard case .container(let c) = self, c.children.indices.contains(i) else {
                preconditionFailure("invalid layout path")
            }
            return c.children[i][path.dropFirst()]
        }
        set {
            guard let i = path.first else { self = newValue; return }
            guard case .container(var c) = self, c.children.indices.contains(i) else {
                preconditionFailure("invalid layout path")
            }
            c.children[i][path.dropFirst()] = newValue
            self = .container(c)
        }
    }

    public subscript(path: [Int]) -> LayoutNode {
        get { self[path[...]] }
        set { self[path[...]] = newValue }
    }
}

extension Container {
    public var paneIDs: [PaneID] { children.flatMap(\.paneIDs) }
}

extension LayoutTree {
    public var paneIDs: [PaneID] { root.paneIDs }
    public var paneCount: Int { root.paneIDs.count }
    public func contains(_ paneID: PaneID) -> Bool { root.path(toPane: paneID) != nil }
}
