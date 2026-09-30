import Foundation

/// One diff, open in the editor.
///
/// Holds the request and the loaded diff, and knows how to reload itself. It runs its own
/// `GitModel` against the request's repository rather than borrowing the Git tile's: it
/// outlives the tile that opened it — the pane can be closed, retargeted, or converted into
/// something else — and a diff that stopped refreshing because another pane went away would
/// silently show stale changes.
@MainActor
@Observable
public final class DiffSession {
    public let request: DiffRequest
    public var side: DiffSide {
        didSet { guard side != oldValue else { return }; markStale() }
    }

    public private(set) var diff: FileDiff?
    public private(set) var isLoading = false
    /// Set when what is on screen is known to be behind — a side change, or a return to a
    /// to it after staging. The view reloads on it rather than on every redraw.
    public private(set) var isStale = true
    /// Counts each time the diff goes stale, and is what the view's load is keyed on. The
    /// flag alone cannot be: it drops again the moment a load begins, and a task keyed on
    /// it would be cancelled by its own first line.
    public private(set) var staleCount = 0

    private let model: GitModel

    public init(request: DiffRequest) {
        self.request = request
        self.side = request.sides.first ?? .unstaged
        self.model = GitModel(root: request.repositoryRoot)
    }

    public var sides: [DiffSide] { request.sides }
    public var path: String { request.change.path }

    /// Mark the diff as needing a reload without clearing what is on screen.
    ///
    /// Deliberately not a reload: the file's content stays visible while the new one is
    /// fetched, so coming back to a diff does not flash an empty pane every time.
    public func invalidate() { markStale() }

    private func markStale() {
        isStale = true
        staleCount += 1
    }

    /// Test seam: stand in for a load that has happened, so a test can prove that coming
    /// back to a diff marks it stale again without running git.
    func markLoadedForTesting() { isStale = false }

    public func loadIfNeeded() async {
        guard isStale, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Round again if it went stale while git was running — the side was switched, or
        // the row was clicked again. The call that arrives for that finds this one still
        // loading and leaves, so this is the only one that can fetch what it asked for.
        while isStale {
            isStale = false
            let loaded = await model.diff(for: request.change, side: side)
            if !isStale { diff = loaded }
        }
    }
}
