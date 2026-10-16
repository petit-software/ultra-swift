import Foundation
import UltraLayout

/// The end of an agent's turn: it worked, then went quiet and stayed quiet.
///
/// What a notification is about. An interactive agent — `claude`, `codex` at their own
/// prompt — never EXITS between turns, so `AgentCompletionTracker`, which watches for the
/// process going away, has nothing to say about the moment that matters: the answer is in,
/// or a permission prompt is up, and the user who walked away is wanted back.
public struct AgentTurnEnd: Equatable, Sendable {
    public let paneID: PaneID
    public let agent: String
    /// From the turn's first output to its last.
    public let duration: TimeInterval
    /// The agent rang `BEL` as it stopped: it asked, rather than merely fell silent.
    public let rangBell: Bool
}

/// Turns a series of per-pane statuses into turn ends, once each.
///
/// Built on `AgentStatusTracker`'s `needsInput`, which is already the sidebar's "gone
/// quiet", and stricter than it in one way: the sidebar may say "waiting" after five
/// seconds and take it back when a slow tool call prints again, but a notification cannot
/// be taken back, so without a bell this waits out `silence` before it believes the turn
/// is over. A bell is the agent saying so, and is believed at once.
public struct AgentTurnTracker: Equatable, Sendable {
    /// How long an agent has to be silent, with no bell, before its turn is taken to have
    /// ended. A build or a test run that prints nothing for ten seconds is a tool call in
    /// the middle of a turn, and most of them are shorter than this.
    public static let silence: TimeInterval = 15

    /// A bell within this long of the last output belongs to the stop, not to a tool call
    /// earlier in the turn — the same agents ring on those too, and then go on printing.
    public static let bellSlack: TimeInterval = 1

    struct Turn: Equatable, Sendable {
        var agent: String
        var startedAt: Date
        /// Reported, or taken to have ended without being news. Either way the next output
        /// from this pane starts a NEW turn rather than stretching this one, so a turn's
        /// duration is a turn's and not the whole afternoon's.
        var ended = false
    }

    private var turns: [PaneID: Turn] = [:]

    public init() {}

    /// Fold one round of samples and their statuses in; return the turns that ended since.
    ///
    /// Only turns this tracker saw BEGIN are reported: an agent already quiet when the app
    /// started has nothing new to say, and a notification at launch about it would be a
    /// notification about the past.
    public mutating func observe(_ samples: [PaneID: AgentPaneSample],
                                 statuses: [PaneID: AgentStatus],
                                 at now: Date) -> [AgentTurnEnd] {
        var ends: [AgentTurnEnd] = []
        for (paneID, sample) in samples {
            guard let agent = sample.agent else {
                turns[paneID] = nil
                continue
            }
            switch statuses[paneID] ?? .idle {
            case .working:
                if let turn = turns[paneID], turn.agent == agent, !turn.ended { continue }
                turns[paneID] = Turn(agent: agent, startedAt: sample.lastOutputAt ?? now)
            case .needsInput:
                guard var turn = turns[paneID], turn.agent == agent, !turn.ended,
                      let last = sample.lastOutputAt else { continue }
                let rang = sample.lastBellAt.map { last.timeIntervalSince($0) <= Self.bellSlack } ?? false
                guard rang || now.timeIntervalSince(last) >= Self.silence else { continue }
                turn.ended = true
                turns[paneID] = turn
                ends.append(AgentTurnEnd(paneID: paneID, agent: agent,
                                         duration: last.timeIntervalSince(turn.startedAt),
                                         rangBell: rang))
            case .idle:
                turns[paneID] = nil
            }
        }
        // A pane that no longer exists cannot have a turn.
        turns = turns.filter { samples[$0.key] != nil }
        // Stable, so a tick that ends two turns at once reports them in one order.
        return ends.sorted { $0.agent < $1.agent }
    }
}
