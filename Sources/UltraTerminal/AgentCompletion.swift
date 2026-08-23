import Foundation
import UltraLayout

/// One agent, seen running.
public struct RunningAgent: Equatable, Sendable {
    public var command: String
    public var startedAt: Date

    public init(command: String, startedAt: Date) {
        self.command = command
        self.startedAt = startedAt
    }
}

/// An agent that has stopped.
public struct AgentCompletion: Equatable, Sendable {
    public let command: String
    public let duration: TimeInterval
}

/// Turns a series of "which panes have an agent right now" samples into completions.
///
/// Keyed by PANE, not counted. A count cannot tell "one finished and another started" from
/// "nothing happened", and those are exactly the two cases this has to separate to say
/// anything true — a count that stays at 1 across a handover would report no completion at
/// all, and one that dips would report a completion for whichever agent it felt like.
public struct AgentCompletionTracker: Equatable, Sendable {
    public private(set) var running: [PaneID: RunningAgent] = [:]

    public init() {}

    /// Fold one sample in, and return whatever finished between this sample and the last.
    ///
    /// A pane whose agent is REPLACED by a different one — the user quits `claude` and starts
    /// `codex` in the same pane between two ticks — reports the first as finished and starts
    /// the clock on the second. Treating that as "still running" would silently attribute the
    /// first agent's time to the second.
    public mutating func observe(_ present: [PaneID: String],
                                 at timestamp: Date) -> [AgentCompletion] {
        var completions: [AgentCompletion] = []

        for (paneID, agent) in running where present[paneID] != agent.command {
            completions.append(AgentCompletion(
                command: agent.command,
                duration: timestamp.timeIntervalSince(agent.startedAt)))
        }

        for (paneID, command) in present where running[paneID]?.command != command {
            running[paneID] = RunningAgent(command: command, startedAt: timestamp)
        }
        running = running.filter { present[$0.key] != nil }

        // Stable, so a tick that ends two agents at once does not announce them in an order
        // that changes between runs.
        return completions.sorted { $0.command < $1.command }
    }
}

/// Decides whether an agent finishing is worth interrupting someone about.
public enum AgentCompletionPolicy {
    /// Below this, a finished agent is not news.
    ///
    /// A command that takes three seconds is a command, not a task you walked away from, and
    /// a notification for one arrives after you have already seen the result — which is how
    /// people learn to turn notifications off.
    public static let minimumDuration: TimeInterval = 30

    /// - Parameter isWatching: the app is active AND something of ours is on screen.
    public static func shouldNotify(duration: TimeInterval,
                                    isEnabled: Bool,
                                    isWatching: Bool) -> Bool {
        guard isEnabled else { return false }
        // Someone looking at the pane has already been told, by the pane.
        guard !isWatching else { return false }
        return duration >= minimumDuration
    }

    /// The agent's own name, because "an agent finished" is useless to anyone running two.
    public static func message(command: String,
                               duration: TimeInterval) -> (title: String, body: String) {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let elapsed = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        return ("\(command) finished", "Ran for \(elapsed).")
    }
}
