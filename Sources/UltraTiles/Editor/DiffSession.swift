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
        didSet { guard side != oldValue else { return }; isStale = true }
    }

    public private(set) var diff: FileDiff?
    public private(set) var isLoading = false
    /// Set when what is on screen is known to be behind — a side change, or a return to a
    /// to it after staging. The view reloads on it rather than on every redraw.
    public private(set) var isStale = true

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
    public func invalidate() { isStale = true }

    /// Test seam: stand in for a load that has happened, so a test can prove that coming
    /// back to a diff marks it stale again without running git.
    func markLoadedForTesting() { isStale = false }

    public func loadIfNeeded() async {
        guard isStale, !isLoading else { return }
        isLoading = true
        isStale = false
        diff = await model.diff(for: request.change, side: side)
        isLoading = false
    }
}
