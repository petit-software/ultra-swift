import Foundation

extension LayoutTree {
    /// Panes in a grid, as close to square as the count allows: one row of one or two,
    /// then two rows of two, two of three, three of three, and so on, each row the same
    /// height and every pane in a row the same width. The last row holds what is left.
    ///
    /// For a canvas whose arrangement is computed rather than edited — the Agents
    /// overview, which shows however many agents there happen to be. Focus is on the
    /// first pane; the caller moves it. Nil for no panes, since a tree cannot be empty.
    public static func grid(of panes: [PaneID], focused: PaneID? = nil) -> LayoutTree? {
        guard let first = panes.first else { return nil }
        let columns = Int(Double(panes.count).squareRoot().rounded(.up))
        var rows: [LayoutNode] = []
        for start in stride(from: 0, to: panes.count, by: columns) {
            let row = panes[start..<min(start + columns, panes.count)].map { LayoutNode.pane($0) }
            rows.append(row.count == 1 ? row[0] : .container(Container(axis: .horizontal, children: row)))
        }
        let root = rows.count == 1 ? rows[0] : .container(Container(axis: .vertical, children: rows))
        let wanted = focused.flatMap { panes.contains($0) ? $0 : nil } ?? first
        return LayoutTree(root: root, focused: wanted)
    }
}
