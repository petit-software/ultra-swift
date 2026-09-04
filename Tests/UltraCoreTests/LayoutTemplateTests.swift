import Testing
import Foundation
@testable import UltraCore
@testable import UltraLayout

/// Copying one project's arrangement onto another: the SHAPE travels, the ties to the
/// project it came from do not.
@Suite("Layout template")
struct LayoutTemplateTests {

    private func source() -> WorkspaceDocument {
        let tree = LayoutTree.fixture(.sidebarMain)
        let ids = tree.paneIDs
        var panes: [PaneID: PaneRecord] = [:]
        panes[ids[0]] = PaneRecord(kind: .fileTree, title: "src", subtitle: nil,
                                   icon: "folder", cwd: "/Users/x/Repo/a/src")
        panes[ids[1]] = PaneRecord(kind: .shell, title: "~/Repo/a", cwd: "/Users/x/Repo/a",
                                   command: "claude", tileState: Data([1, 2, 3]))
        for id in ids.dropFirst(2) {
            panes[id] = PaneRecord(kind: .editor, title: "main.swift", icon: "doc.text",
                                   cwd: "/Users/x/Repo/a", command: "/Users/x/Repo/a/main.swift")
        }
        return WorkspaceDocument(directory: "/Users/x/Repo/a", title: "a", tree: tree, panes: panes)
    }

    private func target() -> WorkspaceDocument {
        let tree = LayoutTree.fixture(.single)
        let panes = [tree.focused: PaneRecord(kind: .shell, title: "b", cwd: "/Users/x/Repo/b")]
        return WorkspaceDocument(directory: "/Users/x/Repo/b", title: "b", tree: tree,
                                 panes: panes, windowFrame: CGRect(x: 1, y: 2, width: 300, height: 200))
    }

    @Test("the shape is copied, the identity is not")
    func shapeTravelsIdentityStays() {
        let from = source()
        let to = target()
        let adopted = to.adoptingLayout(of: from)

        #expect(adopted.id == to.id)
        #expect(adopted.directory == to.directory)
        #expect(adopted.title == "b")
        #expect(adopted.windowFrame == to.windowFrame)
        #expect(adopted.isConsistent)

        // Same number of panes, same kinds in the same order, same fractions.
        #expect(adopted.tree.paneCount == from.tree.paneCount)
        let kindsBefore = from.tree.paneIDs.map { from.record(for: $0)?.kind }
        let kindsAfter = adopted.tree.paneIDs.map { adopted.record(for: $0)?.kind }
        #expect(kindsBefore == kindsAfter)
        #expect(adopted.tree.root.asContainer?.fractions == from.tree.root.asContainer?.fractions)
    }

    @Test("every pane id is fresh, and focus follows the renamed pane")
    func idsAreFresh() {
        let from = source()
        let adopted = target().adoptingLayout(of: from)
        #expect(Set(adopted.tree.paneIDs).isDisjoint(with: from.tree.paneIDs))
        let focusedIndex = from.tree.paneIDs.firstIndex(of: from.tree.focused)
        #expect(adopted.tree.paneIDs.firstIndex(of: adopted.tree.focused) == focusedIndex)
        #expect(adopted.tree.contains(adopted.tree.focused))
    }

    @Test("panes inside the source project are pointed at the target project")
    func foldersAreRehomed() {
        let from = source()
        let adopted = target().adoptingLayout(of: from)
        let records = adopted.tree.paneIDs.compactMap { adopted.record(for: $0) }
        for record in records {
            #expect(record.cwd == "/Users/x/Repo/b", "\(record.kind) still points at the source")
            #expect(record.tileState == nil)
        }
        let shell = try? #require(records.first { $0.kind == .shell })
        // An agent pane stays an agent pane: that is a kind of pane, not a file.
        #expect(shell?.command == "claude")
        let editor = records.first { $0.kind == .editor }
        // The open file lived in the other project.
        #expect(editor?.command == nil)
    }

    @Test("a pane pointed outside the source project keeps its folder")
    func externalFoldersStay() {
        var from = source()
        let id = from.tree.paneIDs[0]
        from.setRecord(PaneRecord(kind: .todo, title: "Todo", cwd: "/Users/x/Notes"), for: id)
        let adopted = target().adoptingLayout(of: from)
        let todo = adopted.tree.paneIDs.compactMap { adopted.record(for: $0) }
            .first { $0.kind == .todo }
        #expect(todo?.cwd == "/Users/x/Notes")
    }
}
