import Testing
import AppKit
import Foundation
import CoreGraphics
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

@Suite("Quit and relaunch")
@MainActor
struct RestoreTests {

    private func storage() -> WorkspaceStorage {
        WorkspaceStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-restore-\(UUID().uuidString)"),
                         debounce: .milliseconds(10))
    }

    /// The M1 acceptance criterion: build a layout, quit, relaunch pixel-identical.
    @Test("a built layout reopens with identical frames")
    func layoutSurvivesRelaunch() {
        let store = storage()
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let before = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: "~/Repo")
        before.canvasBounds = bounds
        let first = before.tree.focused
        before.split(edge: .right, paneID: first)
        before.split(edge: .bottom, paneID: before.tree.focused)
        before.split(edge: .right, paneID: first)
        // A deliberately awkward divider position, so equal-fraction defaults cannot pass.
        let divider = before.layoutResult.dividers[0]
        before.apply("Resize Panes") {
            $0.resize(divider: divider.ref, by: 91, containerSize: divider.containerSize,
                      minPaneSize: 160) != 0
        }
        before.persistNow()

        let after = LayoutStore.restored(from: store, title: "wrong", subtitle: "wrong")
        after.canvasBounds = bounds

        #expect(after.tree == before.tree)
        #expect(after.workspaceTitle == "ultra-swift", "saved identity must win over defaults")
        #expect(layout(after.tree, in: bounds).frames == layout(before.tree, in: bounds).frames)
    }

    @Test("each pane comes back as the same pane, not renumbered")
    func paneIdentitySurvives() {
        let store = storage()
        let before = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        before.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        before.split(edge: .right)
        before.split(edge: .bottom)
        // Materialise the surfaces so records exist, as they would on screen.
        let titlesBefore = before.tree.paneIDs.map { before.surfaces.surfaceRecord(for: $0).title }
        before.persistNow()

        let after = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        let titlesAfter = after.tree.paneIDs.map { after.surfaces.surfaceRecord(for: $0).title }
        #expect(titlesAfter == titlesBefore, "panes were renumbered across a relaunch")
    }

    @Test("focus is restored, however it was last moved")
    func focusSurvives() {
        for move in ["direct", "directional", "numbered"] {
            let store = storage()
            let before = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
            before.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
            before.split(edge: .right)
            before.split(edge: .bottom)

            switch move {
            case "direct": before.focus(before.tree.paneIDs[0])
            case "directional": before.moveFocus(.left)
            default: before.focusPane(atVisualIndex: 0)
            }
            let expected = before.tree.focused
            before.persistNow()

            let after = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
            #expect(after.tree.focused == expected, "focus moved by \(move) was not persisted")
        }
    }

    @Test("the window frame is restored")
    func windowFrameSurvives() {
        let store = storage()
        let frame = CGRect(x: 240, y: 180, width: 1340, height: 902)
        let before = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        before.noteWindowFrame(frame)
        before.persistNow()

        let after = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        #expect(after.windowFrame == frame)
    }

    @Test("a corrupt workspace file opens a default layout instead of failing to launch")
    func corruptFileStillLaunches() throws {
        let store = storage()
        let before = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        before.split(edge: .right)
        before.persistNow()
        try Data("{{{".utf8).write(to: store.url(for: before.workspaceID))

        let after = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        #expect(after.tree.paneCount == 1)
        #expect(after.tree.validate().isEmpty)
    }

    @Test("a zoomed pane does not come back zoomed with its siblings lost")
    func zoomStateIsSane() {
        let store = storage()
        let before = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        before.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        before.split(edge: .right)
        before.toggleZoom()
        before.persistNow()

        let after = LayoutStore.restored(from: store, title: "ultra-swift", subtitle: nil)
        #expect(after.tree.paneCount == 2, "the hidden sibling must still exist")
        #expect(after.tree.zoomed == before.tree.zoomed)
    }
}

/// The store is what actually writes the document, so the directory has to survive the trip
/// from `ShellWorkspace.make` through `LayoutStore.document` to disk. The storage-level
/// tests prove lookup works; this proves the value ever gets there.
@Suite("Workspace directory reaches the document")
@MainActor
struct WorkspaceDirectoryPersistenceTests {

    private func store() -> LayoutStore {
        let factory = PlaceholderPaneFactory()
        return LayoutStore(tree: .fixture(.twoAcross)) { factory.makeContent(for: $0) }
    }

    @Test("a store's directory is written into its document")
    func directoryReachesDocument() {
        let store = store()
        store.workspaceDirectory = "/tmp/alpha"
        #expect(store.document.directory == "/tmp/alpha")
        #expect(store.document.version == WorkspaceDocument.currentVersion)
    }

    /// The document is canonicalised on the way in, so a store handed a path with a trailing
    /// slash still writes the one spelling everything else looks up by.
    @Test("the written directory is the canonical spelling")
    func directoryIsCanonical() {
        let store = store()
        store.workspaceDirectory = "/tmp/alpha/"
        #expect(store.document.directory == "/tmp/alpha")
    }

    @Test("a store with no directory writes none, rather than inventing one")
    func noDirectoryWritesNil() {
        #expect(store().document.directory == nil)
    }
}

/// The tab label and the project name are two different questions.
///
/// They were one value, so every tab on a project read identically and none of them moved
/// when a shell changed directory — the tab row answered "which project" three times over
/// instead of "where am I" once each.
@Suite("Window title follows the focused pane")
@MainActor
struct WindowTitleTests {

    /// Surfaces are materialised up front: `updateRecord` silently drops a record for a pane
    /// that has never been shown, which makes a test look like a logic failure when it is
    /// really a fixture that never built the pane.
    private func store() -> LayoutStore {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.twoAcross)) { factory.makeContent(for: $0) }
        store.workspaceTitle = "ultra"
        for paneID in store.tree.paneIDs { _ = store.surfaces.surface(for: paneID) }
        return store
    }

    @Test("with no directory to show, the project name stands in")
    func fallsBackToProject() {
        let store = store()
        store.refreshWindowTitle()
        #expect(store.windowTitle == "ultra")
    }

    @Test("a focused pane's directory becomes the tab label")
    func followsFocusedPane() {
        let store = store()
        let paneID = store.tree.paneIDs[0]
        store.surfaces.updateRecord(
            PaneRecord(kind: .shell, title: "x", cwd: "/Users/x/Repo/tailor"), for: paneID)
        store.focus(paneID)
        store.refreshWindowTitle()
        #expect(store.windowTitle == "tailor", "the tab says where you are, not what project")
    }

    /// Two panes in different directories: the label follows FOCUS, so moving between them
    /// changes the tab rather than leaving it on whichever pane happened to report last.
    @Test("moving focus moves the title")
    func focusChangesTitle() {
        let store = store()
        let a = store.tree.paneIDs[0], b = store.tree.paneIDs[1]
        store.surfaces.updateRecord(PaneRecord(kind: .shell, title: "a", cwd: "/tmp/alpha"), for: a)
        store.surfaces.updateRecord(PaneRecord(kind: .shell, title: "b", cwd: "/tmp/beta"), for: b)
        store.focus(a)
        store.refreshWindowTitle()
        #expect(store.windowTitle == "alpha")
        store.focus(b)
        #expect(store.windowTitle == "beta")
    }

    /// A tile has no directory. Blanking the tab would be worse than saying the project.
    @Test("a pane with no directory leaves the project name showing")
    func tileKeepsProjectName() {
        let store = store()
        let paneID = store.tree.paneIDs[0]
        store.surfaces.updateRecord(PaneRecord(kind: .todo, title: "Todo"), for: paneID)
        store.focus(paneID)
        store.refreshWindowTitle()
        #expect(store.windowTitle == "ultra")
    }

    /// The DOCUMENT keeps the project name — the tab label is a view of the moment and must
    /// not be what a workspace is called in recents.
    @Test("the saved document still records the project, not the current directory")
    func documentKeepsTheProject() {
        let store = store()
        let paneID = store.tree.paneIDs[0]
        store.surfaces.updateRecord(
            PaneRecord(kind: .shell, title: "x", cwd: "/tmp/somewhere-else"), for: paneID)
        store.focus(paneID)
        store.refreshWindowTitle()
        #expect(store.windowTitle == "somewhere-else")
        #expect(store.document.title == "ultra")
    }
}
