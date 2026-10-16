import Foundation
import UltraLayout

/// What the agent in a pane is doing right now, as far as the tty can honestly tell.
///
/// Derived, not reported. No agent CLI tells this app anything — `AgentChannel` carries
/// `open` and `reveal` and deliberately nothing else — so every state here is read from
/// facts the terminal layer already has: which executable owns the tty's foreground process
/// group, when the pane last produced a byte, and when it last rang `BEL`. See
/// `AgentStatusTracker` for how they combine.
///
/// Only LIVE states. There were `done` and `failed` too, sticky, for the sidebar to show
/// after the agent had gone — and with them a rule for putting them away. The word on a
/// finished turn is a system notification now (`AgentTurnTracker`, `AgentMonitor`), which
/// is where someone who has looked away will actually see it, and the row shows only what
/// is happening in it at this moment.
public enum AgentStatus: String, Equatable, Sendable, CaseIterable {
    /// No agent in this pane.
    case idle
    /// An agent owns the tty and is producing output.
    case working
    /// An agent owns the tty and has gone quiet — a permission prompt, or the end of a turn.
    case needsInput

    /// What a rollup keeps: a session with one agent still printing is working.
    var urgency: Int {
        switch self {
        case .idle: 0
        case .needsInput: 1
        case .working: 2
        }
    }

    /// One session's answer, from every pane in it. Empty is `idle`.
    public static func rollup(_ statuses: some Sequence<AgentStatus>) -> AgentStatus {
        statuses.max { $0.urgency < $1.urgency } ?? .idle
    }
}

/// The facts one pane offers on a tick. Everything `AgentStatusTracker` is allowed to know.
///
/// A struct rather than four parallel dictionaries because the rules read across the fields
/// — "an agent is present AND has been quiet" — and a sample where one field is a tick older
/// than another cannot be reasoned about at all.
public struct AgentPaneSample: Equatable, Sendable {
    /// The agent owning the tty right now, or nil for a plain shell — or for a pane whose
    /// agent has just exited, which is the transition the whole type exists to catch.
    public var agent: String?
    /// When this pane last produced output. Nil for a pane that has never printed anything.
    public var lastOutputAt: Date?
    /// When this pane last rang `BEL`.
    public var lastBellAt: Date?

    public init(agent: String? = nil, lastOutputAt: Date? = nil, lastBellAt: Date? = nil) {
        self.agent = agent
        self.lastOutputAt = lastOutputAt
        self.lastBellAt = lastBellAt
    }
}

/// Reads a status off each pane's sample.
///
/// A pure function of the sample, kept as a type for the thresholds it owns and for the
/// `statusByPane` it hands the monitor each tick — and because it was stateful once, when
/// it remembered finished agents for the sidebar, and may need to be again.
public struct AgentStatusTracker: Equatable, Sendable {

    /// How long an agent has to be silent before it is taken to be waiting.
    ///
    /// Five seconds because a working agent is not quiet: every agent CLI this app is built
    /// around redraws a spinner or an elapsed-time line several times a second, so silence
    /// really does mean the turn has ended. Long enough that a slow tool call — a build, a
    /// test run — does not flicker the row yellow in the middle of working.
    public static let quiet: TimeInterval = 5

    /// The same question asked of a pane that has just rung `BEL`.
    ///
    /// A bell is an agent SAYING it wants attention — a permission prompt, the end of a turn
    /// — so it converts the guess above into something close to a report, and the wait drops
    /// to the length of the redraw that follows the ring. It is a shortcut, not a trigger:
    /// the same agents also ring on tool calls, and a bell followed by more output is an
    /// agent that carried on working.
    public static let quietAfterBell: TimeInterval = 1

    /// How long a ring stays relevant. Past this the bell was about an earlier turn.
    public static let bellWindow: TimeInterval = 30

    public private(set) var statusByPane: [PaneID: AgentStatus] = [:]

    public init() {}

    public func status(for paneID: PaneID) -> AgentStatus {
        statusByPane[paneID] ?? .idle
    }

    /// Read one round of samples and return the status of every pane sampled.
    ///
    /// Panes NOT in the sample are dropped: a pane that no longer exists cannot have a
    /// status, and keeping one would leak a row's badge into whatever pane id came next.
    @discardableResult
    public mutating func observe(_ samples: [PaneID: AgentPaneSample],
                                 at timestamp: Date) -> [PaneID: AgentStatus] {
        statusByPane = samples.mapValues { sample in
            guard sample.agent != nil else { return .idle }
            return isWaiting(sample, at: timestamp) ? .needsInput : .working
        }
        return statusByPane
    }

    private func isWaiting(_ sample: AgentPaneSample, at timestamp: Date) -> Bool {
        // A pane that has never printed anything has not gone quiet — it has not started.
        // Treating "no output ever" as infinite silence would badge an agent as waiting in
        // the moment between the fork and its first byte.
        guard let lastOutputAt = sample.lastOutputAt else { return false }
        let silence = timestamp.timeIntervalSince(lastOutputAt)
        if let bell = sample.lastBellAt, timestamp.timeIntervalSince(bell) <= Self.bellWindow {
            return silence >= Self.quietAfterBell
        }
        return silence >= Self.quiet
    }

}
