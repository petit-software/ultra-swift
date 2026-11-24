import Foundation
import UltraLayout

/// Where a session's agent work stands, for the sidebar: the five states a person picks up
/// a glance — working, needs you, done and not looked at, done, inactive — each with the
/// moment it began, which is what the row's "4m" counts from.
///
/// Built on `AgentStatus`, which is the tty's moment-to-moment answer, and stricter than it
/// where a glance would be misled:
///
/// - QUIET IS NOT DONE until it has lasted. A build or a test run inside a turn prints
///   nothing for seconds at a time; `AgentStatus` calls that `needsInput` after five, and a
///   row that said "done" and then "working" again would be lying twice. So quiet becomes
///   done after `AgentTurnTracker.silence`, or at once when the agent rang `BEL` as it
///   stopped, which is it saying so.
/// - QUIET IS NOT ASKING. An agent that has finished and an agent waiting on a permission
///   prompt look the same to a tty — silent, in front. The difference is on the screen,
///   so "needs you" is read from it (`AgentPrompt`): a question, a y/n, a numbered choice.
/// - DONE IS NEWS ONCE. A finished turn is unread until its session has been looked at —
///   on screen in a window that has the keyboard — and only then plain "done". Half an
///   hour after that, with nothing new, it is inactive.
public enum AgentState: Equatable, Sendable {
    case working(since: Date)
    case needsYou(since: Date)
    case done(at: Date, read: Bool)
    case inactive(since: Date)

    /// When the state began.
    public var since: Date {
        switch self {
        case .working(let date), .needsYou(let date), .inactive(let date): date
        case .done(let date, _): date
        }
    }

    public var isUnread: Bool {
        if case .done(_, read: false) = self { return true }
        return false
    }

    /// How long ago `since` was, the way the row says it: "now" inside a minute, then
    /// minutes, hours and days, whole, the largest unit that fits.
    public func age(at now: Date) -> String {
        Self.age(of: now.timeIntervalSince(since))
    }

    public static func age(of interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// Several panes' states as one: a session's row, from its panes.
    ///
    /// The one that needs a person wins — asking, then working — each since the earliest
    /// of its kind, which is how long someone has been waited on. With nothing live, done
    /// since the LAST finish, unread if any is unread; inactive only when every pane is.
    /// Nil for no states at all.
    public static func rollup(_ states: some Sequence<AgentState>) -> AgentState? {
        var asking: [Date] = [], working: [Date] = [], done: [(Date, Bool)] = [], inactive: [Date] = []
        for state in states {
            switch state {
            case .needsYou(let since): asking.append(since)
            case .working(let since): working.append(since)
            case .done(let at, let read): done.append((at, read))
            case .inactive(let since): inactive.append(since)
            }
        }
        if let since = asking.min() { return .needsYou(since: since) }
        if let since = working.min() { return .working(since: since) }
        if let at = done.map(\.0).max() { return .done(at: at, read: done.allSatisfy(\.1)) }
        if let since = inactive.max() { return .inactive(since: since) }
        return nil
    }
}

/// Whether the last lines of an agent's screen are asking the person something.
///
/// The agents this app is built around ask in a handful of shapes: Claude Code's
/// "Do you want to proceed?" over a numbered menu with a `❯` on the choice, Codex's
/// "Allow command?" and its own numbered menu, and the y/n of every tool that ever asked
/// for confirmation. Matched on the bottom of the screen only — a question scrolled up
/// out of the way was answered. Pure, so it is tested against real screens.
public enum AgentPrompt {
    /// How many lines from the bottom are looked at: a menu with a few choices and its
    /// question fit in this, a page of output above them does not.
    public static let lines = 14

    private static let questions = [
        "do you want to", "would you like to", "allow command", "allow this", "approve",
        "permission", "proceed?", "continue?", "are you sure",
    ]

    public static func isAsking(_ screen: [String]) -> Bool {
        // Inside a box the line starts with its border: "│ ❯ 1. Yes │".
        let frame = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃|╭╮╰╯─━┌┐└┘"))
        let tail = screen.suffix(lines).map { $0.trimmingCharacters(in: frame) }.filter { !$0.isEmpty }
        guard !tail.isEmpty else { return false }
        let lowered = tail.map { $0.lowercased() }
        // A y/n anywhere at the bottom is a question, whatever words come before it.
        if lowered.contains(where: { $0.range(of: #"[\[(]\s*y(es)?\s*/\s*n(o)?\s*[\])]"#, options: .regularExpression) != nil }) {
            return true
        }
        let hasQuestion = lowered.contains { line in questions.contains { line.contains($0) } }
        // A numbered menu with a pointer on one of its choices: "❯ 1. Yes".
        let hasMenu = tail.contains { $0.range(of: #"^[❯›>▶]\s*\d+[.)]\s"#, options: .regularExpression) != nil }
        let hasChoices = tail.filter { $0.range(of: #"^([❯›>▶]\s*)?\d+[.)]\s+\S"#, options: .regularExpression) != nil }.count >= 2
        return hasQuestion && (hasMenu || hasChoices) || hasMenu && hasChoices
    }
}

/// One pane on one tick, as the state tracker reads it.
public struct AgentPaneReading: Equatable, Sendable {
    public var sample: AgentPaneSample
    public var status: AgentStatus
    /// Whether the pane's screen is asking something (`AgentPrompt`).
    public var asking: Bool

    public init(sample: AgentPaneSample, status: AgentStatus, asking: Bool) {
        self.sample = sample
        self.status = status
        self.asking = asking
    }
}

/// Reads each pane's `AgentState`, remembering what it needs to — when a state began, and
/// whether a finished turn has been seen — and rolls the panes of a session up into one.
///
/// PER PANE, with the session derived: the sidebar's row wants one answer per session and
/// the Agents overview wants one per pane, and two trackers would be two ways of being
/// wrong about the same tty. The rollup keeps the state that needs a person first
/// (`AgentState.rollup`).
public struct AgentStateTracker: Equatable, Sendable {
    /// How long a turn that has been seen stays "done" before it is "inactive".
    public static let inactiveAfter: TimeInterval = 1800

    public private(set) var stateByPane: [PaneID: AgentState] = [:]
    public private(set) var stateBySession: [UUID: AgentState] = [:]

    /// A session put away by hand (`markInactive`): since when its row counts, and the
    /// finished turns that went with it, as they were, for `markActive` to put back.
    public struct PutAway: Equatable, Sendable {
        public var since: Date
        public var restoring: [PaneID: AgentState]
        /// Put back from the last launch (`restoreInactive`) rather than put away in
        /// this one. A restored pane relaunches its agent, and the banner it prints is
        /// output like any other — so for these an agent seen working for the FIRST
        /// time is it starting, not a turn, and does not bring the session back.
        public var restored = false
    }

    /// The sessions put away by hand. Each is inactive whatever its panes say, until a
    /// new turn begins in it or it is marked active.
    public private(set) var putAway: [UUID: PutAway] = [:]

    public init() {}

    /// Fold one tick in. `viewed` is the sessions on screen in a window with the keyboard:
    /// looking at a finished turn is what reads it.
    ///
    /// A pane with no agent and no history has no state, and a session whose panes have
    /// none has none, unless it was put away by hand. Panes not in `readings` are
    /// dropped — a closed pane cannot have news.
    @discardableResult
    public mutating func observe(_ readings: [UUID: [PaneID: AgentPaneReading]],
                                 viewed: Set<UUID>, at now: Date) -> [UUID: AgentState] {
        var nextPanes: [PaneID: AgentState] = [:]
        var nextSessions: [UUID: AgentState] = [:]
        for (session, panes) in readings {
            let isViewed = viewed.contains(session)
            var states: [AgentState] = []
            var turnBegan = false
            let restored = putAway[session]?.restored == true
            for (paneID, pane) in panes {
                let previous = stateByPane[paneID]
                guard let state = Self.state(of: pane, previous: previous,
                                             viewed: isViewed, at: now) else { continue }
                if case .working = state {
                    if case .working = previous {} else if previous != nil || !restored { turnBegan = true }
                }
                nextPanes[paneID] = state
                states.append(state)
            }
            // A new turn is what brings a session back from being put away.
            if turnBegan { putAway[session] = nil }
            if let rolled = AgentState.rollup(states) { nextSessions[session] = rolled }
        }
        // Put away by hand, a session is inactive whatever its panes say — and one with
        // no agent, or no terminal, has a state only because of it.
        for (session, mark) in putAway { nextSessions[session] = .inactive(since: mark.since) }
        stateByPane = nextPanes
        stateBySession = nextSessions
        return nextSessions
    }

    /// Put a session away now, whatever it is doing, rather than half an hour after its
    /// last turn was read: the session is inactive, and each of `panes` that is done is
    /// inactive since when it finished. A pane still working or asking keeps its own
    /// state — the Agents overview goes on saying what it is doing — but the session's
    /// row does not: it is put away until a new turn BEGINS in it (`observe`), so a
    /// turn that was running when it was marked finishes without bringing it back.
    /// A session with no agent at all is put away the same way.
    public mutating func markInactive(_ session: UUID, panes: some Sequence<PaneID>, at now: Date = Date()) {
        var states: [AgentState] = []
        var restoring: [PaneID: AgentState] = putAway[session]?.restoring ?? [:]
        for paneID in panes {
            guard var state = stateByPane[paneID] else { continue }
            if case .done(let at, _) = state {
                restoring[paneID] = state
                state = .inactive(since: at)
                stateByPane[paneID] = state
            }
            states.append(state)
        }
        // Since its last finish when all of it had finished; since now when it was
        // put away in the middle of something, or had nothing to finish.
        var since = putAway[session]?.since ?? now
        if case .inactive(let finished) = AgentState.rollup(states) { since = finished }
        putAway[session] = PutAway(since: since, restoring: restoring)
        stateBySession[session] = .inactive(since: since)
    }

    /// The sessions that are inactive, by hand or by the clock, and since when: what is
    /// written down so the next launch can have them inactive still (`restoreInactive`).
    public var inactiveSessions: [UUID: Date] {
        stateBySession.compactMapValues { state in
            if case .inactive(let since) = state { return since }
            return nil
        }
    }

    /// Put back the sessions that were inactive when the app last quit. Nothing of an
    /// agent's state outlives the app — a fresh launch reads every pane for the first
    /// time — so without this a project put away comes back as if it never had been.
    /// Each is put away as if by hand: inactive whatever its panes say, until a new turn
    /// begins in it or it is marked active. One the clock had made inactive comes back
    /// the same way, since the finished turn it was counting from is gone.
    public mutating func restoreInactive(_ sessions: [UUID: Date]) {
        for (session, since) in sessions where putAway[session] == nil {
            putAway[session] = PutAway(since: since, restoring: [:], restored: true)
            stateBySession[session] = .inactive(since: since)
        }
    }

    /// Undo `markInactive`: the session is as its panes say again, and the finished turns
    /// that were put away with it are done as they were. Nothing for a session that went
    /// inactive by the clock — that one was not put away by hand.
    public mutating func markActive(_ session: UUID, panes: some Sequence<PaneID>) {
        guard let mark = putAway.removeValue(forKey: session) else { return }
        var states: [AgentState] = []
        for paneID in panes {
            guard var state = stateByPane[paneID] else { continue }
            if case .inactive = state, let was = mark.restoring[paneID] {
                state = was
                stateByPane[paneID] = state
            }
            states.append(state)
        }
        stateBySession[session] = AgentState.rollup(states)
    }

    /// One pane's state from its reading and what it was a tick ago.
    static func state(of pane: AgentPaneReading, previous: AgentState?,
                      viewed: Bool, at now: Date) -> AgentState? {
        let present = pane.sample.agent != nil
        let quiet = present && pane.status == .needsInput
        if quiet, pane.asking {
            if case .needsYou(let since) = previous { return .needsYou(since: since) }
            return .needsYou(since: now)
        }
        let stopped = quiet && hasStopped(pane.sample, at: now)
        let busy = present && pane.status == .working || (quiet && !stopped)
        if busy {
            if case .working(let since) = previous { return .working(since: since) }
            return .working(since: now)
        }
        // Nothing working and nothing asking: a turn that has ended — the agent quiet at
        // its prompt, or gone altogether — or nothing ever happened here.
        switch previous {
        case nil:
            // A quiet agent the tracker never saw work is done too: an app launched on a
            // pane whose agent is waiting at its prompt. Read, because it is not news.
            return stopped ? .done(at: now, read: true) : nil
        case .working, .needsYou:
            // Watched as it finished, it was read as it finished.
            return .done(at: now, read: viewed)
        case .done(let at, let read):
            let read = read || viewed
            return read && now.timeIntervalSince(at) >= Self.inactiveAfter
                ? .inactive(since: at) : .done(at: at, read: read)
        case .inactive(let since):
            return .inactive(since: since)
        }
    }

    /// A quiet agent has really stopped — not paused mid-turn on a slow tool call — once it
    /// has been silent for the turn tracker's whole `silence`, or at once if it rang as it
    /// stopped.
    static func hasStopped(_ sample: AgentPaneSample, at now: Date) -> Bool {
        guard let last = sample.lastOutputAt else { return true }
        if let bell = sample.lastBellAt, last.timeIntervalSince(bell) <= AgentTurnTracker.bellSlack {
            return true
        }
        return now.timeIntervalSince(last) >= AgentTurnTracker.silence
    }
}
