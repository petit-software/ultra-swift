import Testing
import AppKit
import Foundation
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTiles

/// What is open has to survive the things that rebuild a pane, and a pane has to be
/// findable from outside. Those two facts are what let the Git tile put a diff into an
/// editor that already exists instead of splitting a new pane for every file clicked.
@Suite("Editor panes hold their sessions")
@MainActor
struct EditorPaneRoutingTests {

    private func factory() -> TileFactory {
        TileFactory(context: .inert(root: URL(fileURLWithPath: NSTemporaryDirectory())))
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    @Test("an editor pane is findable, and other tiles are not")
    func onlyEditorsAreEditorPanes() {
        let factory = factory()
        let editor = PaneID(), git = PaneID(), todo = PaneID()

        factory.stage(.editor); _ = factory.makeContent(for: editor)
        factory.stage(.git);    _ = factory.makeContent(for: git)
        factory.stage(.todo);   _ = factory.makeContent(for: todo)

        #expect(factory.editorPanes() == [editor])
        #expect(factory.editorSessions(for: editor) != nil)
        #expect(factory.editorSessions(for: git) == nil)
    }

    /// The reason this is owned by the factory and not by the view. A pane is rebuilt whenever
    /// it is restored or converted, and state living in `@State` would go with it.
    @Test("rebuilding a pane keeps what was open")
    func rebuildKeepsTabs() {
        let factory = factory()
        let paneID = PaneID()
        factory.stage(.editor)
        _ = factory.makeContent(for: paneID)

        let open = try! #require(factory.editorSessions(for: paneID))
        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))

        // What a retarget or a restore does: ask for the content again.
        _ = factory.makeContent(for: paneID)

        #expect(factory.editorSessions(for: paneID) === open)
        #expect(open.sessions.count == 2, "a rebuild must not close what was open")
    }

    @Test("a staged request is what a brand-new editor pane opens on")
    func stagedRequestOpensTheNewPane() {
        let factory = factory()
        let paneID = PaneID()
        factory.stage(open: .file(url("staged.swift")))
        factory.stage(.editor)
        let content = factory.makeContent(for: paneID)

        let open = try! #require(factory.editorSessions(for: paneID))
        #expect(open.sessions.count == 1)
        #expect(open.selected?.title == "staged.swift")
        // The header names the file, not the word "Editor" — see `noteEditorSelection`.
        #expect(content?.record.title == "staged.swift")
    }

    /// Consumed once, the same rule `stage(_ kind:)` follows: opening one file must not turn
    /// every later editor pane into a second view of it.
    @Test("a staged request is consumed once")
    func stagedRequestIsConsumedOnce() {
        let factory = factory()
        let first = PaneID(), second = PaneID()

        factory.stage(open: .file(url("once.swift")))
        factory.stage(.editor); _ = factory.makeContent(for: first)
        factory.stage(.editor); _ = factory.makeContent(for: second)

        #expect(factory.editorSessions(for: first)?.sessions.count == 1)
        #expect(factory.editorSessions(for: second)?.isEmpty == true)
    }

    @Test("closing a pane lets go of what it held")
    func releaseDropsTheSession() {
        let factory = factory()
        let paneID = PaneID()
        factory.stage(.editor)
        _ = factory.makeContent(for: paneID)
        factory.editorSessions(for: paneID)?.open(.file(url("a.swift")))

        factory.release(paneID)

        #expect(factory.editorSessions(for: paneID) == nil)
        #expect(factory.editorPanes().isEmpty)
    }

    /// Only the selected FILE is persisted. A diff is a view of state that moves — restoring
    /// one would reopen a diff of changes that may since have been committed.
    @Test("the pane record follows what is showing, and never claims a diff is a document")
    func recordFollowsWhatIsShowing() {
        let factory = factory()
        let paneID = PaneID()
        var announced: [PaneRecord] = []
        factory.onRecordChange = { _, record in announced.append(record) }

        factory.stage(.editor)
        _ = factory.makeContent(for: paneID)
        let open = try! #require(factory.editorSessions(for: paneID))

        open.open(.file(url("real.swift")))
        #expect(announced.last?.title == "real.swift")
        #expect(announced.last?.command == url("real.swift").path,
                "a file tab is what a restored pane reopens")

        open.open(.diff(DiffRequest(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
            change: GitModel.Change(path: "Sources/App.swift", staged: .modified,
                                    unstaged: .unmodified),
            sides: [.staged])))
        #expect(announced.last?.title == "App.swift")
        #expect(announced.last?.subtitle == "diff")
        #expect(announced.last?.command == nil, "a diff must not be restored as an open file")
    }
}
