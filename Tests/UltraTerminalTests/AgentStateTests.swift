import Foundation
import Testing
@testable import UltraLayout
@testable import UltraTerminal

/// What an agent's screen says, read for the one thing a glance needs: is it asking?
@Suite("Agent prompt")
struct AgentPromptTests {

    @Test("Claude Code's permission box, boxed, with its pointer on a numbered choice")
    func claudePermission() {
        let screen = """
        ⏺ I'll remove the build folder.
        ╭──────────────────────────────────────────────────────────────╮
        │ Bash command                                                 │
        │                                                              │
        │   rm -rf build                                               │
        │   Remove the build folder                                    │
        │                                                              │
        │ Do you want to proceed?                                      │
        │ ❯ 1. Yes                                                     │
        │   2. Yes, and don't ask again for rm commands in this folder │
        │   3. No, and tell Claude what to do differently (esc)        │
        ╰──────────────────────────────────────────────────────────────╯
        """.components(separatedBy: "\n")
        #expect(AgentPrompt.isAsking(screen))
    }

    @Test("Codex asking to run a command")
    func codexApproval() {
        let screen = """
        Allow command?

          $ swift build

        › 1. Yes (y)
          2. Yes, always for this session (a)
          3. No, provide feedback (esc)
        """.components(separatedBy: "\n")
        #expect(AgentPrompt.isAsking(screen))
    }

    @Test("a y/n anywhere at the bottom is a question")
    func yesNo() {
        #expect(AgentPrompt.isAsking(["Overwrite package.json? [y/N]"]))
        #expect(AgentPrompt.isAsking(["Continue (yes/no)"]))
    }

    @Test("a finished turn at its prompt is not asking, nor is a list in the answer")
    func notAsking() {
        let done = """
        ⏺ Done. I updated three files:
          1. Sources/App.swift
          2. Sources/Model.swift
          3. Tests/ModelTests.swift
        ╭──────────────────────────────────────────╮
        │ >                                        │
        ╰──────────────────────────────────────────╯
          ? for shortcuts
        """.components(separatedBy: "\n")
        #expect(!AgentPrompt.isAsking(done))
        #expect(!AgentPrompt.isAsking([]))
        #expect(!AgentPrompt.isAsking(["", "   "]))
    }

    @Test("a question scrolled far up is not the bottom of the screen")
    func onlyTheBottom() {
        let old = ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        let after = Array(repeating: "building…", count: AgentPrompt.lines)
        #expect(!AgentPrompt.isAsking(old + after))
    }
}

/// The sidebar's five states, from a session's panes over time.
@Suite("Agent state")
struct AgentStateTests {
    private let session = UUID()
    private let pane = PaneID()
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func reading(_ status: AgentStatus, lastOutput: Date?, bell: Date? = nil, asking: Bool = false,
                         agent: String? = "claude") -> [UUID: [PaneID: AgentPaneReading]] {
        [session: [pane: AgentPaneReading(sample: AgentPaneSample(agent: status == .idle ? nil : agent,
                                                                    lastOutputAt: lastOutput, lastBellAt: bell),
                                          status: status, asking: asking)]]
    }

    @Test("working, then quiet long enough is done and unread, and looking at it reads it")
    func turn() {
        var tracker = AgentStateTracker()
        tracker.observe(reading(.working, lastOutput: t0), viewed: [], at: t0)
        #expect(tracker.stateBySession[session] == .working(since: t0))
        // Quiet a few seconds: a slow tool call, still working, still since the start.
        let t1 = t0.addingTimeInterval(8)
        tracker.observe(reading(.needsInput, lastOutput: t0), viewed: [], at: t1)
        #expect(tracker.stateBySession[session] == .working(since: t0))
        // Quiet past the turn tracker's silence: done, and nobody has seen it.
        let t2 = t0.addingTimeInterval(AgentTurnTracker.silence + 1)
        tracker.observe(reading(.needsInput, lastOutput: t0), viewed: [], at: t2)
        #expect(tracker.stateBySession[session] == .done(at: t2, read: false))
        #expect(tracker.stateBySession[session]?.isUnread == true)
        let t3 = t2.addingTimeInterval(60)
        tracker.observe(reading(.needsInput, lastOutput: t0), viewed: [session], at: t3)
        #expect(tracker.stateBySession[session] == .done(at: t2, read: true))
    }

    @Test("a bell as it stops is done at once")
    func bellIsDone() {
        var tracker = AgentStateTracker()
        tracker.observe(reading(.working, lastOutput: t0), viewed: [], at: t0)
        let quiet = t0.addingTimeInterval(2)
        tracker.observe(reading(.needsInput, lastOutput: t0, bell: t0), viewed: [], at: quiet)
        #expect(tracker.stateBySession[session] == .done(at: quiet, read: false))
    }

    @Test("quiet and asking is needs-you, ahead of a pane that is still working")
    func needsYou() {
        var tracker = AgentStateTracker()
        let other = PaneID()
        var readings = reading(.needsInput, lastOutput: t0, asking: true)
        readings[session]?[other] = AgentPaneReading(sample: AgentPaneSample(agent: "codex", lastOutputAt: t0),
                                                     status: .working, asking: false)
        let t1 = t0.addingTimeInterval(6)
        tracker.observe(readings, viewed: [], at: t1)
        #expect(tracker.stateBySession[session] == .needsYou(since: t1))
        // Still asking a minute later: since when it started asking.
        tracker.observe(readings, viewed: [session], at: t1.addingTimeInterval(60))
        #expect(tracker.stateBySession[session] == .needsYou(since: t1))
    }

    @Test("an agent that exits ends its turn; a watched finish is read; an hour later it is inactive")
    func exitAndInactive() {
        var tracker = AgentStateTracker()
        tracker.observe(reading(.working, lastOutput: t0), viewed: [session], at: t0)
        let t1 = t0.addingTimeInterval(30)
        tracker.observe(reading(.idle, lastOutput: t0), viewed: [session], at: t1)
        #expect(tracker.stateBySession[session] == .done(at: t1, read: true))
        let t2 = t1.addingTimeInterval(AgentStateTracker.inactiveAfter + 1)
        tracker.observe(reading(.idle, lastOutput: t0), viewed: [], at: t2)
        #expect(tracker.stateBySession[session] == .inactive(since: t1))
    }

    @Test("an unread finish never goes inactive by itself")
    func unreadStays() {
        var tracker = AgentStateTracker()
        tracker.observe(reading(.working, lastOutput: t0), viewed: [], at: t0)
        let t1 = t0.addingTimeInterval(30)
        tracker.observe(reading(.idle, lastOutput: t0), viewed: [], at: t1)
        tracker.observe(reading(.idle, lastOutput: t0), viewed: [], at: t1.addingTimeInterval(86_400 * 3))
        #expect(tracker.stateBySession[session] == .done(at: t1, read: false))
    }

    @Test("a session with no agent and no history has no state; a closed one is forgotten")
    func noHistory() {
        var tracker = AgentStateTracker()
        tracker.observe(reading(.idle, lastOutput: nil), viewed: [], at: t0)
        #expect(tracker.stateBySession[session] == nil)
        tracker.observe(reading(.working, lastOutput: t0), viewed: [], at: t0)
        tracker.observe([:], viewed: [], at: t0)
        #expect(tracker.stateBySession.isEmpty)
    }

    @Test("an agent already quiet at launch is done, and not news")
    func quietAtLaunch() {
        var tracker = AgentStateTracker()
        let late = t0.addingTimeInterval(AgentTurnTracker.silence + 5)
        tracker.observe(reading(.needsInput, lastOutput: t0), viewed: [], at: late)
        #expect(tracker.stateBySession[session] == .done(at: late, read: true))
    }

    @Test("ages read the way the row says them")
    func ages() {
        #expect(AgentState.age(of: 5) == "now")
        #expect(AgentState.age(of: 59) == "now")
        #expect(AgentState.age(of: 61) == "1m")
        #expect(AgentState.age(of: 60 * 12) == "12m")
        #expect(AgentState.age(of: 3600 * 5) == "5h")
        #expect(AgentState.age(of: 86_400 * 2 + 10) == "2d")
        #expect(AgentState.age(of: -4) == "now")
    }
}
