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
