import Testing
import Foundation
@testable import UltraTiles

/// The editor's sidebar holds everything open, so clicking four changed files fills one
/// pane instead of splitting four. These cover the rules that make that read as one editor
/// rather than a pile of documents.
@Suite("Editor sessions")
@MainActor
struct EditorSessionTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/ultra-tests/\(name)")
    }

    private func diff(_ path: String, root: String = "/tmp/repo") -> EditorRequest {
        .diff(DiffRequest(repositoryRoot: URL(fileURLWithPath: root),
                          change: GitModel.Change(path: path, staged: .modified,
                                                  unstaged: .unmodified),
                          sides: [.staged]))
    }

    @Test("opening several files lists them all, and the last one wins the view")
    func severalFilesListedTogether() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))
        open.open(.file(url("c.swift")))

        #expect(open.sessions.count == 3)
        #expect(open.selected?.title == "c.swift")
    }

    /// Clicking the same row twice is a request to LOOK at it. Answering with a duplicate is
    /// how an editor ends up with nine copies of one file and no way to tell them apart.
    @Test("opening the same file again reuses its row")
    func reopeningReusesTheRow() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))
        open.open(.file(url("a.swift")))

        #expect(open.sessions.count == 2)
        #expect(open.selected?.title == "a.swift", "it is selected, not merely present")
    }

    /// A file and its diff are two different things to look at, so they are two rows — in two
    /// different sections — even though they name the same path.
    @Test("a file and its diff are listed separately")
    func fileAndDiffCoexist() {
        let open = EditorSessions()
        open.open(.file(URL(fileURLWithPath: "/tmp/repo/Sources/App.swift")))
        open.open(diff("Sources/App.swift"))

        #expect(open.sessions.count == 2)
        #expect(open.sessions.filter(\.isDiff).count == 1)
        #expect(open.selected?.isDiff == true)
    }

    @Test("reopening a diff reuses its row and marks it for a refresh")
    func reopeningADiffRefreshesIt() {
        let open = EditorSessions()
        let item = open.open(diff("Sources/App.swift"))
        guard case .diff(let model) = item.content else { Issue.record("not a diff"); return }

        // Pretend it has loaded, then ask for it again — staging a hunk elsewhere is
        // exactly this sequence, and a cached diff would show the pre-staging state.
        model.markLoadedForTesting()
        #expect(!model.isStale)
        open.open(diff("Sources/App.swift"))
        #expect(open.sessions.count == 1)
        #expect(model.isStale, "coming back to a diff must show what the file looks like now")
    }

    /// Never "the first one": that throws the user back to the top of a long list for closing
    /// something at the bottom of it.
    @Test("closing what is showing lands on the neighbour above it")
    func closingSelectsTheNeighbourAbove() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))
        open.open(.file(url("c.swift")))
        let middle = open.sessions[1]

        open.select(middle.id)
        open.close(middle.id)

        #expect(open.sessions.count == 2)
        #expect(open.selected?.title == "a.swift")
    }

    @Test("closing something that is not showing leaves the view where it was")
    func closingAnotherTabDoesNotMoveTheView() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))
        let first = open.sessions[0]

        #expect(open.selected?.title == "b.swift")
        open.close(first.id)
        #expect(open.selected?.title == "b.swift", "closing elsewhere must not steal the view")
    }

    @Test("closing the last tab leaves an empty editor, not a dangling selection")
    func closingTheLastOneEmpties() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.closeSelected()

        #expect(open.isEmpty)
        #expect(open.selected == nil)
    }

    @Test("next and previous wrap around the list")
    func tabCyclingWraps() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))
        open.open(.file(url("c.swift")))   // selected

        open.selectNext()
        #expect(open.selected?.title == "a.swift", "past the end is the beginning")
        open.selectPrevious()
        #expect(open.selected?.title == "c.swift", "and back again")
        open.selectPrevious()
        #expect(open.selected?.title == "b.swift")
    }

    @Test("cycling a single tab is a no-op rather than a wobble")
    func cyclingOneEntryDoesNothing() {
        let open = EditorSessions()
        open.open(.file(url("a.swift")))
        open.selectNext()
        open.selectPrevious()
        #expect(open.selected?.title == "a.swift")
    }

    /// The pane header names the file being shown. Without this a window of four editors reads
    /// "Editor" four times over.
    @Test("the header is told whenever the visible session changes")
    func selectionIsAnnounced() {
        let open = EditorSessions()
        var announced: [String?] = []
        open.onSelectionChange = { announced.append($0) }

        open.open(.file(url("a.swift")))
        open.open(.file(url("b.swift")))
        open.selectPrevious()
        open.closeSelected()
        open.closeSelected()

        #expect(announced.compactMap { $0 }.map { ($0 as NSString).lastPathComponent }
                == ["a.swift", "b.swift", "a.swift", "b.swift"])
        #expect(announced.last == .some(nil), "an empty editor says so")
    }

    @Test("a diff opens on a side the file actually has")
    func diffOpensOnAnAvailableSide() {
        let open = EditorSessions()
        let item = open.open(diff("Sources/App.swift"))
        guard case .diff(let model) = item.content else { Issue.record("not a diff"); return }
        #expect(model.side == .staged, "the picker must never open on an empty side")
    }
}
