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
///   on screen in a window that has the keyboard — and only then plain "done". An hour
///   after that, with nothing new, it is inactive.
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

/// Turns each session's panes into one `AgentState`, remembering what it needs to: when a
/// state began, and whether a finished turn has been seen.
public struct AgentStateTracker: Equatable, Sendable {
    /// How long a turn that has been seen stays "done" before it is "inactive".
    public static let inactiveAfter: TimeInterval = 3600

    public private(set) var stateBySession: [UUID: AgentState] = [:]

    public init() {}

    /// Fold one tick in. `viewed` is the sessions on screen in a window with the keyboard:
    /// looking at a finished turn is what reads it.
    ///
    /// A session with no agent and no history has no state. Sessions not in `readings`
    /// are dropped — a closed session cannot have news.
    @discardableResult
    public mutating func observe(_ readings: [UUID: [PaneID: AgentPaneReading]],
                                 viewed: Set<UUID>, at now: Date) -> [UUID: AgentState] {
        var next: [UUID: AgentState] = [:]
        for (session, panes) in readings {
            let previous = stateBySession[session]
            let isViewed = viewed.contains(session)
            let panes = Array(panes.values)
            let quiet = panes.filter { $0.sample.agent != nil && $0.status == .needsInput }

            if quiet.contains(where: \.asking) {
                if case .needsYou(let since) = previous { next[session] = .needsYou(since: since) }
                else { next[session] = .needsYou(since: now) }
                continue
            }
            let stopped = quiet.filter { Self.hasStopped($0.sample, at: now) }
            let busy = panes.contains { $0.sample.agent != nil && $0.status == .working }
                || quiet.count > stopped.count
            if busy {
                if case .working(let since) = previous { next[session] = .working(since: since) }
                else { next[session] = .working(since: now) }
                continue
            }
            // Nothing working and nothing asking: a turn that has ended — the agent quiet at
            // its prompt, or gone altogether — or nothing ever happened here.
            switch previous {
            case nil:
                // Quiet agents the tracker never saw work are done too: an app launched on a
                // session whose agent is waiting at its prompt. Read, because it is not news.
                if !stopped.isEmpty { next[session] = .done(at: now, read: true) }
            case .working, .needsYou:
                // Watched as it finished, it was read as it finished.
                next[session] = .done(at: now, read: isViewed)
            case .done(let at, let read):
                let read = read || isViewed
                next[session] = read && now.timeIntervalSince(at) >= Self.inactiveAfter
                    ? .inactive(since: at) : .done(at: at, read: read)
            case .inactive(let since):
                next[session] = .inactive(since: since)
            }
        }
        stateBySession = next
        return next
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
