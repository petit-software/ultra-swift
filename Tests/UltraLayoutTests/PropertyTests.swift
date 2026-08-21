import Testing
import Foundation
import CoreGraphics
@testable import UltraLayout

/// A random but reproducible sequence of user actions.
private enum Op: CaseIterable {
    case split, close, resize, resizePush, move, swap, zoom, equalize
}

private struct Harness {
    var tree: LayoutTree
    var rng: SeededRNG
    var nextPane = 100
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var metrics = LayoutMetrics.default

    init(seed: UInt64) {
        tree = LayoutTree(single: LayoutTree.fixturePane(1))
        rng = SeededRNG(seed: seed)
    }

    mutating func randomPane() -> PaneID {
        let panes = tree.paneIDs
        return panes[rng.int(0..<panes.count)]
    }

    mutating func step() {
        let op = Op.allCases[rng.int(0..<Op.allCases.count)]
        let edges = Edge.allCases
        switch op {
        case .split:
            guard tree.paneCount < 24 else { return }
            let target = randomPane()
            let edge = edges[rng.int(0..<edges.count)]
            guard canSplit(tree, pane: target, edge: edge, in: bounds, metrics: metrics) else { return }
            nextPane += 1
            tree.split(target, edge: edge, newPane: LayoutTree.fixturePane(nextPane),
                       ratio: 0.2 + rng.double() * 0.6)
        case .close:
            guard tree.paneCount > 1 else { return }
            tree.close(randomPane())
        case .resize, .resizePush:
            let result = layout(tree, in: bounds, metrics: metrics)
            guard !result.dividers.isEmpty else { return }
            let divider = result.dividers[rng.int(0..<result.dividers.count)]
            tree.resize(divider: divider.ref,
                        by: CGFloat(rng.int(-400..<400)),
                        containerSize: divider.containerSize,
                        minPaneSize: metrics.minPaneSize.size(along: divider.axis),
                        mode: op == .resizePush ? .push : .hardStop)
        case .move:
            guard tree.paneCount > 2 else { return }
            tree.move(randomPane(), toEdgeOf: randomPane(), edge: edges[rng.int(0..<edges.count)])
        case .swap:
            tree.swap(randomPane(), randomPane())
        case .zoom:
            tree.toggleZoom(randomPane())
        case .equalize:
            if rng.int(0..<2) == 0 { tree.equalizeAll() }
        }
    }
}

@Suite("Invariants under random operation sequences")
struct PropertyTests {

    /// 200 sequences × 50 operations = 10,000 operations, every one of them checked.
    @Test("invariants hold after every operation", arguments: 0..<200)
    func invariants(seed: Int) {
        var harness = Harness(seed: UInt64(seed))
        for step in 0..<50 {
            harness.step()
            let problems = harness.tree.validate()
            #expect(problems.isEmpty, "seed \(seed) step \(step): \(problems)")
        }
    }

    @Test("frames tile the canvas exactly, however the tree was built", arguments: 0..<60)
    func framesAlwaysTile(seed: Int) {
        var harness = Harness(seed: UInt64(seed) &+ 9_000)
        let expected = harness.metrics.contentRect(in: harness.bounds)
            .snapped(to: harness.metrics.scale)

        for _ in 0..<40 {
            harness.step()
            guard harness.tree.zoomed == nil else { continue }
            let frames = layout(harness.tree, in: harness.bounds, metrics: harness.metrics).frames
            #expect(frames.count == harness.tree.paneCount)

            let union = frames.values.reduce(CGRect.null) { $0.union($1) }
            #expect(abs(union.minX - expected.minX) < 0.01 && abs(union.maxX - expected.maxX) < 0.01,
                    "seed \(seed): union \(union) != \(expected)")
            #expect(abs(union.minY - expected.minY) < 0.01 && abs(union.maxY - expected.maxY) < 0.01,
                    "seed \(seed): union \(union) != \(expected)")

            let all = Array(frames.values)
            for i in all.indices {
                for j in all.indices where j > i {
                    let overlap = all[i].intersection(all[j])
                    #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
                            "seed \(seed): \(all[i]) overlaps \(all[j])")
                }
            }
        }
    }

    @Test("close after split restores the exact prior tree", arguments: 0..<40)
    func splitCloseRoundTrip(seed: Int) {
        var harness = Harness(seed: UInt64(seed) &+ 4_000)
        for _ in 0..<12 { harness.step() }
        harness.tree.zoomed = nil

        let before = harness.tree.root
        let target = harness.randomPane()
        let edge = Edge.allCases[harness.rng.int(0..<4)]
        guard canSplit(harness.tree, pane: target, edge: edge, in: harness.bounds) else { return }

        let newPane = LayoutTree.fixturePane(999)
        let didSplit = harness.tree.split(target, edge: edge, newPane: newPane)
        #expect(didSplit)
        let didClose = harness.tree.close(newPane)
        #expect(didClose)
        #expect(harness.tree.root == before, "seed \(seed): split/close was not reversible")
    }

    @Test("every operation sequence survives an encode/decode round-trip", arguments: 0..<40)
    func codableUnderChaos(seed: Int) throws {
        var harness = Harness(seed: UInt64(seed) &+ 2_000)
        for _ in 0..<30 { harness.step() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(harness.tree)
        let decoded = try JSONDecoder().decode(LayoutTree.self, from: data)
        #expect(decoded == harness.tree)
        #expect(decoded.validate().isEmpty)
    }

    @Test("zoom never changes the tree", arguments: 0..<40)
    func zoomIsNonDestructive(seed: Int) {
        var harness = Harness(seed: UInt64(seed) &+ 7_000)
        for _ in 0..<20 { harness.step() }
        harness.tree.zoomed = nil
        let root = harness.tree.root
        for pane in harness.tree.paneIDs {
            harness.tree.toggleZoom(pane)
            #expect(harness.tree.root == root)
            harness.tree.toggleZoom(pane)
            #expect(harness.tree.zoomed == nil)
        }
    }
}
