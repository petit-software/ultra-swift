import Testing
import Foundation
@testable import UltraTerminal
@testable import UltraLayout

private let t0 = Date(timeIntervalSince1970: 2_000_000)
private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// A session row's colour is derived, because nothing reports it. No agent CLI tells this
/// app what it is doing — the control socket carries `open` and `reveal` and nothing else —
/// so every state comes out of the tty's foreground process, when the pane last printed,
/// when it last rang, and what an agent pane exited with.
@Suite("Agent status")
struct AgentStatusTrackerTests {

    private let paneA = PaneID()
    private let paneB = PaneID()

    /// An agent that is printing is an agent that is thinking. Every agent CLI this app is
    /// built around redraws a spinner several times a second, so recent output is the
    /// cheapest possible proof of life.
    @Test("an agent that is printing is working")
    func printingIsWorking() {
        var tracker = AgentStatusTracker()
        let sample = AgentPaneSample(agent: "claude", lastOutputAt: later(9))
        #expect(tracker.observe([paneA: sample], at: later(10)) == [paneA: .working])
    }

    /// The turn has ended, or a permission prompt is up. Either way the agent is now waiting
    /// on a human, which is the one state the row exists to make visible from another window.
    @Test("an agent gone quiet is waiting for input")
    func quietIsWaiting() {
        var tracker = AgentStatusTracker()
        let sample = AgentPaneSample(agent: "claude", lastOutputAt: t0)
        #expect(tracker.observe([paneA: sample], at: later(AgentStatusTracker.quiet))
                == [paneA: .needsInput])
    }

    /// A bell is the agent SAYING it wants attention, so the guess above becomes close to a
    /// report and the wait drops to the length of the redraw that follows the ring.
    @Test("a recent bell shortens the wait")
    func bellShortensTheWait() {
        var tracker = AgentStatusTracker()
        let sample = AgentPaneSample(agent: "claude", lastOutputAt: t0, lastBellAt: t0)
        #expect(tracker.observe([paneA: sample], at: later(2)) == [paneA: .needsInput],
                "two seconds is nowhere near the plain quiet threshold")
    }

    /// The same agents ring on tool calls too, so a bell followed by more output is an agent
    /// that carried on working — the ring is a shortcut, never a trigger on its own.
    @Test("a bell followed by more output is still working")
    func bellThenOutputIsWorking() {
        var tracker = AgentStatusTracker()
        let sample = AgentPaneSample(agent: "claude", lastOutputAt: later(10), lastBellAt: later(9))
        #expect(tracker.observe([paneA: sample], at: later(10.2)) == [paneA: .working])
    }

    @Test("a bell from an earlier turn is not evidence about this one")
    func staleBellIsIgnored() {
        var tracker = AgentStatusTracker()
        let sample = AgentPaneSample(agent: "claude",
                                     lastOutputAt: later(100),
                                     lastBellAt: t0)
        // Two seconds of silence: enough after a fresh bell, not enough on its own.
        #expect(tracker.observe([paneA: sample], at: later(102)) == [paneA: .working],
                "the ring is older than the bell window, so only the plain threshold applies")
    }

    /// The gap between the fork and the first byte. Treating "has never printed" as infinite
    /// silence would badge every agent as waiting in the moment it starts.
    @Test("an agent that has not printed yet is not waiting")
    func noOutputYetIsNotWaiting() {
        var tracker = AgentStatusTracker()
        #expect(tracker.observe([paneA: AgentPaneSample(agent: "claude")], at: later(600))
                == [paneA: .working])
    }

    // MARK: - Leaving

    /// A pane whose agent has gone is a shell. What the agent's leaving MEANS — a
    /// completion worth a notification — is `AgentCompletionTracker`'s to say, from
    /// what it saw on earlier ticks; the status is only ever about now.
    @Test("an agent that disappears leaves an idle pane")
    func disappearingIsIdle() {
        var tracker = AgentStatusTracker()
        _ = tracker.observe([paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        #expect(tracker.observe([paneA: AgentPaneSample(lastOutputAt: t0)], at: later(1))
                == [paneA: .idle])
    }

    @Test("a plain shell that never ran an agent stays idle")
    func plainShellStaysIdle() {
        var tracker = AgentStatusTracker()
        let shell = AgentPaneSample(agent: nil, lastOutputAt: t0)
        #expect(tracker.observe([paneA: shell], at: later(1)) == [paneA: .idle])
        #expect(tracker.observe([paneA: shell], at: later(600)) == [paneA: .idle],
                "silence in a shell at a prompt is not an agent waiting for anything")
    }

    /// A pane id is never reissued, but a status left behind for one that is gone is a badge
    /// counted into a session that no longer contains the pane.
    @Test("a closed pane takes its status with it")
    func closedPaneIsDropped() {
        var tracker = AgentStatusTracker()
        _ = tracker.observe([paneA: AgentPaneSample(agent: "claude", lastOutputAt: t0)], at: t0)
        _ = tracker.observe([:], at: later(1))
        #expect(tracker.statusByPane.isEmpty)
        #expect(tracker.status(for: paneA) == .idle)
    }

    // MARK: - Rolling a session up

    /// A session with one agent still printing is working, whatever the others are doing.
    @Test("a session reports its busiest pane")
    func rollupPrefersWorking() {
        #expect(AgentStatus.rollup([.idle, .needsInput]) == .needsInput)
        #expect(AgentStatus.rollup([.needsInput, .working]) == .working)
        #expect(AgentStatus.rollup([AgentStatus]()) == .idle)
    }

    @Test("a session with nothing running says nothing")
    func rollupOfIdleIsIdle() {
        #expect(AgentStatus.rollup([.idle, .idle, .idle]) == .idle)
    }
}
