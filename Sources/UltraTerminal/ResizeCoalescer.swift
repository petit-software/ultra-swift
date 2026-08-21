import Foundation

/// Decides when a PTY is told about a new size.
///
/// Two independent clocks, and conflating them is what makes terminals feel sluggish while
/// dragging: **frames update on every event, `SIGWINCH` does not**. Issuing `TIOCSWINSZ` per
/// frame floods full-screen TUIs — vim, tmux, an agent CLI's own UI — which redraw on each
/// one, and the terminal visibly stutters.
///
/// Pure and clock-injected, so the policy is unit-tested rather than eyeballed.
/// See docs/01-SPLIT-ENGINE.md § 6.
public struct ResizeCoalescer: Sendable, Equatable {
    /// At most one resize per pane per interval while a drag is in flight.
    public var minimumInterval: TimeInterval
    private var lastSentAt: TimeInterval?
    private var lastGrid: Grid?

    public struct Grid: Equatable, Sendable {
        public var cols: Int
        public var rows: Int
        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    public init(minimumInterval: TimeInterval = 0.033) {
        self.minimumInterval = minimumInterval
    }

    /// Should the PTY be resized now?
    ///
    /// - `isFinal`: the authoritative resize sent after a drag commits. It always goes
    ///   through if the grid differs, so the shell can never be left with a stale size.
    public mutating func shouldSend(_ grid: Grid, at now: TimeInterval, isFinal: Bool = false) -> Bool {
        // A drag of a few points that does not cross a cell boundary produces zero PTY
        // traffic — the pane resizes, the shell never hears about it.
        guard grid != lastGrid else { return false }
        guard grid.cols > 0, grid.rows > 0 else { return false }

        if !isFinal, let lastSentAt, now - lastSentAt < minimumInterval { return false }

        lastGrid = grid
        lastSentAt = now
        return true
    }

    /// Forget the last size — used when a pane's process is replaced.
    public mutating func reset() {
        lastSentAt = nil
        lastGrid = nil
    }

    public var lastSentGrid: Grid? { lastGrid }
}
