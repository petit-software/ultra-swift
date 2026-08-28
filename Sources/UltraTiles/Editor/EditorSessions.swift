import Foundation

/// What the editor has been asked to show.
///
/// One value for both callers, so the routing in the app layer moves a request to a pane
/// without knowing whether it is carrying a file or a diff. The file tree sends files, the
/// Git tile sends diffs, and neither has to know the other exists.
public enum EditorRequest: Equatable, Sendable {
    case file(URL)
    case diff(DiffRequest)

    /// Where the request came from on disk. Used to name a pane and to decide whether it is
    /// already open.
    public var path: String {
        switch self {
        case .file(let url): url.path
        case .diff(let request): request.absolutePath
        }
    }
}

/// One file's diff, as an instruction rather than as content.
///
/// Carries the repository as well as the change: a Git tile can be aimed at a checkout that
/// is not the project's, and a diff resolved against the wrong repository is not a diff, it
/// is a different file's history.
public struct DiffRequest: Equatable, Sendable {
    public let repositoryRoot: URL
    public let change: GitModel.Change
    /// Which sides actually have something to show. Computed by the Git tile, which already
    /// has the status in hand, so the editor never offers a side that is empty by definition.
    public let sides: [DiffSide]

    public init(repositoryRoot: URL, change: GitModel.Change, sides: [DiffSide]) {
        self.repositoryRoot = repositoryRoot
        self.change = change
        self.sides = sides
    }

    public var absolutePath: String {
        repositoryRoot.appendingPathComponent(change.path).path
    }
}

/// One thing the editor has open: a file being edited, or a change being read.
///
/// A class so it has an identity that survives the list being reordered or a neighbour
/// closing — a struct would be re-identified by position, and SwiftUI would tear down the
/// text view (and the cursor, and the scroll position) of a row that never moved.
@MainActor
public final class EditorSession: Identifiable {
    public enum Content {
        case file(EditorDocument)
        case diff(DiffSession)
    }

    public let id = UUID()
    public let content: Content

    init(content: Content) { self.content = content }

    /// What this is showing, on disk. The key for "is it already open".
    public var path: String {
        switch content {
        case .file(let document): document.url?.path ?? ""
        case .diff(let diff): diff.request.absolutePath
        }
    }

    /// The sidebar's label. The last component only — a source list has no room for paths,
    /// and the full one is in the editor's own footer.
    public var title: String {
        (path as NSString).lastPathComponent
    }

    public var isDirty: Bool {
        if case .file(let document) = content { return document.isDirty }
        return false
    }

    public var isDiff: Bool {
        if case .diff = content { return true }
        return false
    }

    public var symbol: String { isDiff ? "plusminus" : "doc.text" }
}

/// The sessions one editor pane is holding.
///
/// Owned by `TileFactory` rather than by the view, for the same reason a shell's PTY is
/// owned outside its view: a pane is rebuilt whenever it is retargeted or restored, and a
/// list that lived in `@State` would take every open file with it. It is also what lets
/// something OUTSIDE the pane — the Git tile, the file tree, an agent's `open` request —
/// add to an editor that already exists rather than splitting another pane off.
@MainActor
@Observable
public final class EditorSessions {
    public private(set) var sessions: [EditorSession] = []
    public private(set) var selectedID: EditorSession.ID?

    /// Announced whenever the visible session changes, so a pane's header can say which file
    /// it is showing rather than the word "Editor" over four different documents.
    @ObservationIgnored public var onSelectionChange: ((String?) -> Void)?

    public init() {}

    public var selected: EditorSession? {
        sessions.first { $0.id == selectedID }
    }

    public var isEmpty: Bool { sessions.isEmpty }

    /// Show something, reusing the row that is already showing it.
    ///
    /// Reuse rather than a second row: clicking the same file twice in a file tree, or the
    /// same row in Git after a refresh, is a request to LOOK at it — answering with a
    /// duplicate is how an editor ends up with nine copies of one document and no way to
    /// tell them apart.
    @discardableResult
    public func open(_ request: EditorRequest) -> EditorSession {
        if let existing = sessions.first(where: { $0.path == request.path && $0.isDiff == request.isDiff }) {
            select(existing.id)
            // A diff is a view of state that moves under it. Coming back to one after
            // staging a hunk must show what the file looks like NOW.
            if case .diff(let diff) = existing.content { diff.invalidate() }
            return existing
        }
        let session: EditorSession = switch request {
        case .file(let url): EditorSession(content: .file(EditorDocument(url: url)))
        case .diff(let diffRequest): EditorSession(content: .diff(DiffSession(request: diffRequest)))
        }
        sessions.append(session)
        select(session.id)
        return session
    }

    public func select(_ id: EditorSession.ID) {
        guard selectedID != id else { return }
        selectedID = id
        onSelectionChange?(selected?.path)
    }

    /// Close one and land on a sensible neighbour.
    ///
    /// The one ABOVE, or the new last one — never "the first", which throws the user back to
    /// the top of a long list for closing something at the bottom of it.
    public func close(_ id: EditorSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        sessions.remove(at: index)
        guard wasSelected else { return }
        if sessions.isEmpty {
            selectedID = nil
            onSelectionChange?(nil)
        } else {
            selectedID = sessions[max(0, index - 1)].id
            onSelectionChange?(selected?.path)
        }
    }

    public func closeSelected() {
        if let selectedID { close(selectedID) }
    }

    /// Wraps, because a row of sessions is a ring in every editor that has them, and stopping at
    /// the end just means pressing the other shortcut.
    public func selectNext() { step(by: 1) }
    public func selectPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        guard sessions.count > 1,
              let current = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        let next = (current + offset + sessions.count) % sessions.count
        select(sessions[next].id)
    }

    /// Whether anything open here has unsaved edits — asked before a pane is closed.
    public var hasUnsavedChanges: Bool { sessions.contains { $0.isDirty } }

    /// Split for the sidebar's two sections. Editing a file and reading a diff are different
    /// kinds of work, and a flat list mixes them into one pile to be searched by icon.
    public var files: [EditorSession] { sessions.filter { !$0.isDiff } }
    public var diffs: [EditorSession] { sessions.filter(\.isDiff) }

    /// Whether the sidebar is showing.
    ///
    /// Lives on the model rather than in the view so a menu command can reach it — a control
    /// that only exists as a button in a footer has no keyboard route, which this app treats
    /// as a bug rather than a gap. The view still overrides it in a pane too narrow to hold
    /// two columns.
    public var isSidebarVisible = true
}

private extension EditorRequest {
    var isDiff: Bool {
        if case .diff = self { return true }
        return false
    }
}
