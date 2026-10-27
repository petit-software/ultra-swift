import Testing
import Foundation
@testable import UltraTerminal
@testable import UltraLayout

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Completions are derived from samples of "which panes have an agent right now", because
/// nothing announces one. An agent typed at a prompt arrives and leaves without any process
/// of ours starting or stopping.
@Suite("Agent completion tracking")
struct AgentCompletionTrackerTests {

    private let paneA = PaneID()
    private let paneB = PaneID()

    @Test("an agent that keeps running is not a completion")
    func stillRunningIsNotDone() {
        var tracker = AgentCompletionTracker()
        #expect(tracker.observe([paneA: "claude"], at: t0).isEmpty)
        #expect(tracker.observe([paneA: "claude"], at: later(60)).isEmpty)
        #expect(tracker.running.count == 1)
    }

    @Test("an agent that disappears completes, with the time it ran")
    func disappearingCompletes() {
        var tracker = AgentCompletionTracker()
        _ = tracker.observe([paneA: "claude"], at: t0)
        let done = tracker.observe([:], at: later(90))
        #expect(done == [AgentCompletion(command: "claude", duration: 90)])
        #expect(tracker.running.isEmpty)
    }

    /// The case a COUNT cannot see. One agent stops and another starts between two ticks, so
    /// the total never moves — and a counter reports nothing happening while one agent
    /// finished and another began.
    @Test("one finishing as another starts is still a completion")
    func handoverIsSeen() {
        var tracker = AgentCompletionTracker()
        _ = tracker.observe([paneA: "claude"], at: t0)
        let done = tracker.observe([paneB: "codex"], at: later(45))
        #expect(done == [AgentCompletion(command: "claude", duration: 45)])
        #expect(tracker.running.count == 1)
    }

    /// Quitting one agent and starting another in the SAME pane. Treating that as "still
    /// running" would hand the first agent's elapsed time to the second.
    @Test("a different agent in the same pane restarts the clock")
    func replacementInPlace() {
        var tracker = AgentCompletionTracker()
        _ = tracker.observe([paneA: "claude"], at: t0)
        let done = tracker.observe([paneA: "codex"], at: later(50))
        #expect(done == [AgentCompletion(command: "claude", duration: 50)])

        let second = tracker.observe([:], at: later(70))
        #expect(second == [AgentCompletion(command: "codex", duration: 20)],
                "the second agent inherited the first's start time")
    }

    @Test("two finishing at once are reported in a stable order")
    func twoAtOnce() {
        var tracker = AgentCompletionTracker()
        _ = tracker.observe([paneA: "zed", paneB: "claude"], at: t0)
        let done = tracker.observe([:], at: later(40))
        #expect(done.map(\.command) == ["claude", "zed"])
    }

    @Test("an empty sample against an empty tracker does nothing")
    func nothingFromNothing() {
        var tracker = AgentCompletionTracker()
        #expect(tracker.observe([:], at: t0).isEmpty)
        #expect(tracker.running.isEmpty)
    }
}

/// Whether a completion is worth interrupting someone about.
@Suite("Agent completion policy")
struct AgentCompletionPolicyTests {

    @Test("off means silent, however long it ran")
    func disabledSaysNothing() {
        #expect(!AgentCompletionPolicy.shouldNotify(duration: 3600, isEnabled: false,
                                                    isWatching: false))
    }

    /// Someone looking at the pane has already been told, by the pane.
    @Test("nothing is said to someone already watching")
    func watchingSaysNothing() {
        #expect(!AgentCompletionPolicy.shouldNotify(duration: 3600, isEnabled: true,
                                                    isWatching: true))
    }

    @Test("a short command is not news", arguments: [0.0, 1, 5, 29, 29.9])
    func shortIsNotNews(duration: TimeInterval) {
        #expect(!AgentCompletionPolicy.shouldNotify(duration: duration, isEnabled: true,
                                                    isWatching: false))
    }

    @Test("a long one is", arguments: [30.0, 31, 600])
    func longIsNews(duration: TimeInterval) {
        #expect(AgentCompletionPolicy.shouldNotify(duration: duration, isEnabled: true,
                                                   isWatching: false))
    }

    @Test("the message names the agent, by its name, and how long it ran")
    func messageNamesTheAgent() {
        let (title, body) = AgentCompletionPolicy.message(command: "claude", duration: 125)
        #expect(title == "Claude Code finished")
        #expect(body == "Ran for 2m 5s.")
    }

    @Test("under a minute reads in seconds alone")
    func secondsOnly() {
        #expect(AgentCompletionPolicy.message(command: "codex", duration: 45).body
                == "Ran for 45s.")
    }

    // MARK: - Turn ends

    @Test("a turn that ended on its own needs the full minimum", arguments: [5.0, 29.9])
    func shortTurnIsNotNews(duration: TimeInterval) {
        #expect(!AgentCompletionPolicy.shouldNotifyTurnEnd(duration: duration, rangBell: false,
                                                           isEnabled: true, isWatching: false))
        #expect(AgentCompletionPolicy.shouldNotifyTurnEnd(duration: 30, rangBell: false,
                                                          isEnabled: true, isWatching: false))
    }

    /// A permission prompt three seconds in is exactly when the user is wanted.
    @Test("a bell lets a short turn through, but not a trivial one")
    func bellLowersTheBar() {
        #expect(AgentCompletionPolicy.shouldNotifyTurnEnd(duration: 5, rangBell: true,
                                                          isEnabled: true, isWatching: false))
        #expect(!AgentCompletionPolicy.shouldNotifyTurnEnd(duration: 1, rangBell: true,
                                                           isEnabled: true, isWatching: false))
    }

    @Test("a turn end is silent when off, or when the user is watching")
    func turnEndGates() {
        #expect(!AgentCompletionPolicy.shouldNotifyTurnEnd(duration: 600, rangBell: true,
                                                           isEnabled: false, isWatching: false))
        #expect(!AgentCompletionPolicy.shouldNotifyTurnEnd(duration: 600, rangBell: true,
                                                           isEnabled: true, isWatching: true))
    }

    /// The project is the title — it is what a stack of notifications is scanned for —
    /// and the agent is named as a person would name it, not as its executable, which for
    /// Claude Code's native install is a version number.
    @Test("the turn message is titled with the project and says who is waiting, by name")
    func turnMessage() {
        let (title, body) = AgentCompletionPolicy.turnMessage(agent: "claude", duration: 130,
                                                              session: "ultra-swift")
        #expect(title == "ultra-swift")
        #expect(body == "Claude Code is waiting for you. Worked for 2m 10s.")
        let scratch = AgentCompletionPolicy.turnMessage(agent: "codex", duration: 45, session: nil)
        #expect(scratch.title == "Codex is waiting for you")
        #expect(scratch.body == "Worked for 45s.")
        // An agent the list has never heard of keeps its executable's name.
        #expect(AgentCompletionPolicy.turnMessage(agent: "aider", duration: 45, session: nil).title
                == "aider is waiting for you")
        #expect(AgentCompletionPolicy.message(command: "claude", duration: 40).title == "Claude Code finished")
    }
}
