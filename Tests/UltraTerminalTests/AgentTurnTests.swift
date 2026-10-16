import Testing
import Foundation
@testable import UltraTerminal
@testable import UltraLayout

private let t0 = Date(timeIntervalSince1970: 3_000_000)
private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// A turn's end is what the notification is about: an interactive agent never exits
/// between turns, so the only sign that the answer is in is the pane going quiet.
@Suite("Agent turns")
struct AgentTurnTrackerTests {

    private let paneA = PaneID()
    private let paneB = PaneID()

    /// One tick: the status is read the way the monitor reads it, then folded in.
    private func tick(_ tracker: inout AgentTurnTracker, _ statuses: inout AgentStatusTracker,
                      _ samples: [PaneID: AgentPaneSample], at now: Date) -> [AgentTurnEnd] {
        statuses.observe(samples, at: now)
        return tracker.observe(samples, statuses: statuses.statusByPane, at: now)
    }

    @Test("a turn that goes quiet and stays quiet ends once, with how long it ran")
    func quietEndsTheTurn() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        let last = AgentPaneSample(agent: "claude", lastOutputAt: later(40))
        _ = tick(&turns, &statuses, [paneA: last], at: later(40))
        // Quiet, but not yet for long enough to be believed without a bell.
        #expect(tick(&turns, &statuses, [paneA: last], at: later(40 + AgentStatusTracker.quiet)).isEmpty)
        let ends = tick(&turns, &statuses, [paneA: last], at: later(40 + AgentTurnTracker.silence))
        #expect(ends == [AgentTurnEnd(paneID: paneA, agent: "claude", duration: 40, rangBell: false)])
        #expect(tick(&turns, &statuses, [paneA: last], at: later(600)).isEmpty,
                "a turn ends once; the pane stays quiet and nothing is said again")
    }

    /// The whole reason this waits longer than the sidebar does: a build that prints
    /// nothing for ten seconds is a tool call, and a notification cannot be taken back.
    @Test("output before the silence is up keeps the turn going")
    func slowToolCallIsNotAnEnd() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        let paused = AgentPaneSample(agent: "claude", lastOutputAt: later(20))
        #expect(tick(&turns, &statuses, [paneA: paused], at: later(30)).isEmpty)
        let resumed = AgentPaneSample(agent: "claude", lastOutputAt: later(31))
        #expect(tick(&turns, &statuses, [paneA: resumed], at: later(31)).isEmpty)
        let done = AgentPaneSample(agent: "claude", lastOutputAt: later(60))
        let ends = tick(&turns, &statuses, [paneA: done], at: later(60 + AgentTurnTracker.silence))
        #expect(ends.map(\.duration) == [60], "one turn from the first output to the last")
    }

    /// A bell is the agent saying it has stopped, so it is believed as soon as the status
    /// is — which with a bell is a second after the ring.
    @Test("a bell as the agent stops ends the turn at once")
    func bellEndsAtOnce() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        let rang = AgentPaneSample(agent: "claude", lastOutputAt: later(10), lastBellAt: later(10))
        let ends = tick(&turns, &statuses, [paneA: rang], at: later(10 + AgentStatusTracker.quietAfterBell))
        #expect(ends == [AgentTurnEnd(paneID: paneA, agent: "claude", duration: 10, rangBell: true)])
    }

    /// The same agents ring on tool calls and then go on printing; that ring is not the
    /// stop, and the end of such a turn is reported as a plain one.
    @Test("a bell earlier in the turn does not count as the stop")
    func midTurnBellIsNotTheStop() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        let done = AgentPaneSample(agent: "claude", lastOutputAt: later(30), lastBellAt: later(5))
        #expect(tick(&turns, &statuses, [paneA: done], at: later(30 + AgentStatusTracker.quiet)).isEmpty)
        let ends = tick(&turns, &statuses, [paneA: done], at: later(30 + AgentTurnTracker.silence))
        #expect(ends.map(\.rangBell) == [false])
    }

    /// The user typed the next prompt: a new turn, with its own clock.
    @Test("output after an ended turn starts a new one")
    func nextTurnStartsFresh() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        let first = AgentPaneSample(agent: "claude", lastOutputAt: later(40))
        _ = tick(&turns, &statuses, [paneA: first], at: later(40 + AgentTurnTracker.silence))
        let again = AgentPaneSample(agent: "claude", lastOutputAt: later(100))
        _ = tick(&turns, &statuses, [paneA: again], at: later(100))
        let second = AgentPaneSample(agent: "claude", lastOutputAt: later(110))
        let ends = tick(&turns, &statuses, [paneA: second], at: later(110 + AgentTurnTracker.silence))
        #expect(ends.map(\.duration) == [10], "not 110: the first turn's time is the first turn's")
    }

    /// An agent already quiet when the app came up has nothing new to say.
    @Test("a turn that was never seen to begin is not reported")
    func unseenTurnIsNotReported() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        let quiet = AgentPaneSample(agent: "claude", lastOutputAt: t0)
        #expect(tick(&turns, &statuses, [paneA: quiet], at: later(600)).isEmpty)
    }

    @Test("an agent that exits mid-turn ends nothing here")
    func exitIsNotATurnEnd() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        #expect(tick(&turns, &statuses, [paneA: AgentPaneSample(lastOutputAt: t0)], at: later(1)).isEmpty,
                "the completion tracker reports exits; two notifications for one event would be two")
        #expect(tick(&turns, &statuses, [paneA: AgentPaneSample(lastOutputAt: t0)], at: later(600)).isEmpty)
    }

    @Test("two panes end in a stable order")
    func stableOrder() {
        var turns = AgentTurnTracker(), statuses = AgentStatusTracker()
        _ = tick(&turns, &statuses, [paneA: AgentPaneSample(agent: "codex", lastOutputAt: t0),
                                     paneB: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        let quiet = [paneA: AgentPaneSample(agent: "codex", lastOutputAt: later(40)),
                     paneB: AgentPaneSample(agent: "claude", lastOutputAt: later(40))]
        let ends = tick(&turns, &statuses, quiet, at: later(40 + AgentTurnTracker.silence))
        #expect(ends.map(\.agent) == ["claude", "codex"])
    }
}
