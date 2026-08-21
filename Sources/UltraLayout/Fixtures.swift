import Foundation

/// Named layouts shared by previews and golden tests.
///
/// They live in the library, not the test target, on purpose: when a golden layout test
/// fails, the same fixture name is already on screen in the Xcode canvas.
/// See docs/05-PREVIEWS.md.
extension LayoutTree {
    public enum Fixture: String, CaseIterable, Sendable {
        case single
        case twoAcross
        case threeAcross
        case grid2x2
        case sidebarMain
        case deepNest

        public var title: String {
            switch self {
            case .single: "Single"
            case .twoAcross: "Two across"
            case .threeAcross: "Three across"
            case .grid2x2: "Grid 2×2"
            case .sidebarMain: "Sidebar + main"
            case .deepNest: "Deep nest"
            }
        }
    }

    /// Deterministic pane IDs, so golden tests and previews agree run to run.
    public static func fixturePane(_ n: Int) -> PaneID {
        PaneID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private static func fixtureNode(_ n: Int) -> NodeID {
        NodeID(uuidString: String(format: "11111111-0000-0000-0000-%012d", n))!
    }

    public static func fixture(_ fixture: Fixture) -> LayoutTree {
        let p = fixturePane
        let n = fixtureNode

        func row(_ id: Int, _ children: [LayoutNode], _ fractions: [Double]? = nil) -> LayoutNode {
            .container(Container(id: n(id), axis: .horizontal, children: children, fractions: fractions))
        }
        func column(_ id: Int, _ children: [LayoutNode], _ fractions: [Double]? = nil) -> LayoutNode {
            .container(Container(id: n(id), axis: .vertical, children: children, fractions: fractions))
        }

        let root: LayoutNode = switch fixture {
        case .single:
            .pane(p(1))
        case .twoAcross:
            row(1, [.pane(p(1)), .pane(p(2))])
        case .threeAcross:
            row(1, [.pane(p(1)), .pane(p(2)), .pane(p(3))])
        case .grid2x2:
            column(1, [row(2, [.pane(p(1)), .pane(p(2))]),
                       row(3, [.pane(p(3)), .pane(p(4))])])
        case .sidebarMain:
            row(1, [.pane(p(1)),
                    column(2, [.pane(p(2)), .pane(p(3))], [0.7, 0.3])],
                [0.25, 0.75])
        case .deepNest:
            row(1, [.pane(p(1)),
                    column(2, [.pane(p(2)),
                               row(3, [.pane(p(3)),
                                       column(4, [.pane(p(4)), .pane(p(5))])],
                                   [0.4, 0.6])],
                           [0.35, 0.65])],
                [0.3, 0.7])
        }

        var tree = LayoutTree(root: root, focused: p(1))
        tree.normalize()
        return tree
    }
}
