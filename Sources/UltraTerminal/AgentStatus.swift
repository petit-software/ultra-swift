import Foundation
import UltraLayout

/// What the agent in a pane is doing, as far as the tty can honestly tell.
///
/// Derived, not reported. No agent CLI tells this app anything — `AgentChannel` carries
/// `open` and `reveal` and deliberately nothing else — so every state here is read from
/// facts the terminal layer already has: which executable owns the tty's foreground process
/// group, when the pane last produced a byte, when it last rang `BEL`, and what a pane whose
/// process WAS the agent exited with. See `AgentStatusTracker` for how they combine.
public enum AgentStatus: String, Equatable, Sendable, CaseIterable {
    /// No agent has run in this pane, or the last one has been acknowledged.
    case idle
    /// An agent owns the tty and is producing output.
    case working
    /// An agent owns the tty and has gone quiet — a permission prompt, or the end of a turn.
    case needsInput
    /// An agent ran and stopped without saying anything went wrong.
    case done
    /// An agent ran and its process exited non-zero.
    case failed

    /// How loudly a state asks for a human, which is what a rollup keeps.
    ///
    /// Ordered by what the user has to DO, not by severity. `needsInput` outranks `failed`
    /// because a stalled agent is blocked on the user *right now* and a failed one has
    /// already stopped — the first is a queue forming, the second is news. `working`
    /// outranks `done` for the same reason a session with one agent still going is not
    /// finished just because another one is.
    var urgency: Int {
        switch self {
        case .idle: 0
        case .done: 1
        case .working: 2
        case .failed: 3
        case .needsInput: 4
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
    /// The exit status of a pane whose process IS the agent — `ShellLauncher` runs
    /// `exec <agent>`, so an agent pane cannot outlive its agent and the code is the agent's.
    ///
    /// Always nil for an agent TYPED at a prompt: the shell reaps it and there is no way to
    /// read `$?` from outside. Such an agent therefore finishes as `done` whatever it
    /// thought of itself, which is the honest answer rather than a guessed one.
    public var exitCode: Int32?

    public init(agent: String? = nil, lastOutputAt: Date? = nil,
                lastBellAt: Date? = nil, exitCode: Int32? = nil) {
        self.agent = agent
        self.lastOutputAt = lastOutputAt
        self.lastBellAt = lastBellAt
        self.exitCode = exitCode
    }
}

/// Folds a series of pane samples into a status per pane.
///
/// Stateful for one reason: `done` and `failed` are not visible in a sample. A pane whose
/// agent has exited looks exactly like a pane that never had one, so the only thing that can
/// tell them apart is having seen the agent on an earlier tick. That is also why the two
/// terminal states are STICKY — a completion shown for the one second it takes the next tick
/// to arrive is a completion nobody sees — and why they need `acknowledge` to clear.
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

    /// Fold one round of samples in and return the new status of every pane sampled.
    ///
    /// Panes NOT in the sample are dropped: a pane that no longer exists cannot have a
    /// status, and keeping one would leak a row's badge into whatever pane id came next.
    @discardableResult
    public mutating func observe(_ samples: [PaneID: AgentPaneSample],
                                 at timestamp: Date) -> [PaneID: AgentStatus] {
        var next: [PaneID: AgentStatus] = [:]
        for (paneID, sample) in samples {
            next[paneID] = status(of: sample, wasRunning: status(for: paneID), at: timestamp)
        }
        statusByPane = next
        return next
    }

    private func status(of sample: AgentPaneSample,
                        wasRunning previous: AgentStatus,
                        at timestamp: Date) -> AgentStatus {
        if sample.agent != nil {
            return isWaiting(sample, at: timestamp) ? .needsInput : .working
        }
        // No agent now. Whether that is a completion or simply a shell depends entirely on
        // what this pane was doing a tick ago — the sample cannot tell the two apart.
        switch previous {
        case .working, .needsInput:
            return (sample.exitCode ?? 0) == 0 ? .done : .failed
        // Sticky: a badge earned on an earlier tick survives until it is acknowledged.
        case .done, .failed:
            return previous
        case .idle:
            return .idle
        }
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

    /// Put a pane's finished badge away. The user has seen it.
    ///
    /// Only `done` and `failed` are cleared: acknowledging a RUNNING agent would blank a
    /// row that is still working, and it would come straight back on the next tick anyway.
    public mutating func acknowledge(_ panes: some Sequence<PaneID>) {
        for paneID in panes {
            switch statusByPane[paneID] {
            case .done, .failed: statusByPane[paneID] = .idle
            default: break
            }
        }
    }
}
