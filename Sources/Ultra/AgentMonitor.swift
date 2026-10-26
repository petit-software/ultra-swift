import AppKit
import Foundation
import UltraDesign
import UltraLayout
import UltraTerminal

/// Watches every workspace for running agents, and tells the app when the answer changes.
///
/// This exists because the answer changes with NO event to hang it on. `onAgentActivityChange`
/// fires when a shell starts or exits, which covers an agent this app launched — but the
/// common case is `claude` typed at a prompt in a shell that was already running, and that
/// arrives and leaves without any process of ours beginning or ending. Read from the tty, the
/// state is true; sampled only on shell lifecycle, nobody is ever told it changed.
///
/// Polled from the APP rather than from a view, which the roadmap is explicit about: a timer
/// living in a view runs per view, keeps running when the view is off screen, and multiplies
/// with tabs. There is one of these.
@MainActor
@Observable
final class AgentMonitor {
    static let shared = AgentMonitor()

    /// How many agents are running across every workspace.
    private(set) var runningCount = 0

    /// Deliberately NOT `TilePolling.tick`, which pauses while the app is occluded.
    ///
    /// A tile behind a hidden window is updating pixels nobody can see, so pausing it is
    /// free. This is the opposite: a window is most likely to be hidden exactly WHILE an
    /// agent runs, and pausing then would mean the badge never clears, the completion is
    /// never noticed, and — worst — the keep-awake assertion is held after the work it was
    /// protecting has finished. That is the laptop-flat-in-a-bag failure the guard exists to
    /// avoid, reintroduced by an optimisation.
    ///
    /// Two syscalls per pane per tick, and no subprocess, so there is nothing to optimise.
    static let interval: Duration = .seconds(1)

    private var task: Task<Void, Never>?

    /// Agents seen running, and since when. The transition logic lives in UltraTerminal so
    /// it can be tested; this holds the clock, the registry and the badge.
    private(set) var tracker = AgentCompletionTracker()

    /// What each pane's agent is doing, and the same answer rolled up per session.
    ///
    /// Rolled up HERE rather than in the sidebar because this is the only place that knows
    /// which panes belong to which workspace — the registry is keyed by workspace, and a
    /// view handed a flat pane→status map would have to reach back through it to find out.
    private(set) var statuses = AgentStatusTracker()
    private(set) var statusBySession: [UUID: AgentStatus] = [:]

    /// What each session's agent work comes to for a glance: working, needs you, done
    /// unread, done, inactive — see `AgentState`. What the sidebar's rows show.
    private(set) var states = AgentStateTracker()
    private(set) var stateBySession: [UUID: AgentState] = [:]
    /// The same, per pane: what the Agents overview's strips show.
    private(set) var stateByPane: [PaneID: AgentState] = [:]

    /// The time, to the minute, for the rows' "4m". Moves once a minute, so a row that
    /// reads it redraws once a minute and no oftener — the rows hold no timers of their own.
    private(set) var minute = Date()

    /// The sessions someone is looking at: the one on screen in the window with the
    /// keyboard, or one of its pane windows. Looking at a finished turn is what reads it.
    var viewedSessions: () -> Set<UUID> = { SessionList.viewedSessions }

    /// The turns, for the notification that an agent has stopped and is waiting. The
    /// transition logic lives in UltraTerminal beside the other two trackers, and for the
    /// same reason: so it can be tested without a tty.
    private(set) var turns = AgentTurnTracker()

    /// Injectable so tests can run the whole transition without a clock or a notification.
    var now: () -> Date = Date.init
    var isWatching: () -> Bool = {
        NSApp?.isActive == true && (NSApp?.windows.contains { $0.isVisible } ?? false)
    }
    /// Title, body, and the session the news is about, so a click on the notification can
    /// go there. Nil for a completion, which no longer has a pane to go to.
    var announce: (String, String, UUID?, PaneID?) -> Void = { title, body, workspaceID, paneID in
        AgentCompletionNotifier.shared.notify(title: title, body: body,
                                              workspaceID: workspaceID, paneID: paneID)
    }

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Read the current answer and publish it if it moved.
    func sample() {
        var present: [PaneID: String] = [:]
        var byWorkspace: [UUID: [PaneID: AgentPaneSample]] = [:]
        for (workspaceID, factory) in ShellWorkspace.Registry.factories {
            let samples = factory.agentSamples
            byWorkspace[workspaceID] = samples
            for (paneID, sample) in samples {
                if let agent = sample.agent { present[paneID] = agent }
            }
        }
        observe(present)
        observeStatuses(byWorkspace)
        // After the states, so a pane arriving on the overview wears its state at once.
        AgentsOverview.shared.refresh(byWorkspace)
    }

    /// Fold one round of per-pane samples into a status for every session.
    ///
    /// Separate from `observe` above, which answers "how many agents are running" for the
    /// dock badge and the sleep assertion. This answers "what should this row look like",
    /// and the two differ in the case the badge does not have: an agent that has FINISHED
    /// still has something to say, and a count has already forgotten it.
    func observeStatuses(_ byWorkspace: [UUID: [PaneID: AgentPaneSample]]) {
        var flattened: [PaneID: AgentPaneSample] = [:]
        var workspaceOfPane: [PaneID: UUID] = [:]
        for (workspaceID, samples) in byWorkspace {
            flattened.merge(samples) { first, _ in first }
            for paneID in samples.keys { workspaceOfPane[paneID] = workspaceID }
        }
        let timestamp = now()
        statuses.observe(flattened, at: timestamp)
        // Once, over every workspace's panes: the tracker forgets panes it is not shown,
        // so showing it one workspace at a time would end every other workspace's turns.
        for end in turns.observe(flattened, statuses: statuses.statusByPane, at: timestamp) {
            announceIfWorthIt(end, in: workspaceOfPane[end.paneID])
        }
        observeStates(byWorkspace, at: timestamp)
        // Rebuilt rather than updated in place, so a session that has closed takes its entry
        // with it instead of leaving a badge behind for a row that no longer exists.
        let rolled = byWorkspace.mapValues { samples in
            AgentStatus.rollup(samples.keys.map { statuses.status(for: $0) })
        }
        // Published only when it actually MOVED. This runs every second, and assigning an
        // equal dictionary to an observed property is still a change as far as Observation is
        // concerned — every row in every sidebar would redraw once a second for news that had
        // not happened. `runningCount` above has always been guarded for the same reason.
        guard rolled != statusBySession else { return }
        statusBySession = rolled
    }

    /// The sidebar's states, from the same samples. Published only when they moved, and
    /// the minute only when it turned: this runs every second.
    private func observeStates(_ byWorkspace: [UUID: [PaneID: AgentPaneSample]], at timestamp: Date) {
        var readings: [UUID: [PaneID: AgentPaneReading]] = [:]
        for (workspaceID, samples) in byWorkspace {
            var panes: [PaneID: AgentPaneReading] = [:]
            for (paneID, sample) in samples {
                let status = statuses.status(for: paneID)
                // The screen is read for a question only while the agent is quiet: a
                // working agent's screen is a spinner, and asking it is wasted work.
                let asking = status == .needsInput && AgentPrompt.isAsking(sample.screen)
                panes[paneID] = AgentPaneReading(sample: sample, status: status, asking: asking)
            }
            readings[workspaceID] = panes
        }
        let next = states.observe(readings, viewed: viewedSessions(), at: timestamp)
        if next != stateBySession { stateBySession = next }
        if states.stateByPane != stateByPane { stateByPane = states.stateByPane }
        let turned = Calendar.current.dateInterval(of: .minute, for: timestamp)?.start ?? timestamp
        if turned != Calendar.current.dateInterval(of: .minute, for: minute)?.start { minute = turned }
    }

    /// Fold one sample into the running set, announcing whatever finished.
    ///
    /// Keyed by pane, not counted, because a count cannot tell "one finished and another
    /// started" from "nothing happened" — and those are the two things this has to
    /// distinguish to say anything true about a completion.
    func observe(_ present: [PaneID: String]) {
        for completion in tracker.observe(present, at: now()) {
            announceIfWorthIt(completion)
        }
        update(to: tracker.running.count)
    }

    private func announceIfWorthIt(_ completion: AgentCompletion) {
        guard AgentCompletionPolicy.shouldNotify(
            duration: completion.duration,
            isEnabled: Preferences.notifiesOnAgentCompletion,
            isWatching: isWatching()) else { return }
        let message = AgentCompletionPolicy.message(command: completion.command,
                                                    duration: completion.duration)
        announce(message.title, message.body, nil, nil)
    }

    /// A turn that ended: the same gates as a completion, with the bell letting a short
    /// turn through, and the session's name in the body so the reader knows where to go.
    private func announceIfWorthIt(_ end: AgentTurnEnd, in workspaceID: UUID?) {
        guard AgentCompletionPolicy.shouldNotifyTurnEnd(
            duration: end.duration,
            rangBell: end.rangBell,
            isEnabled: Preferences.notifiesOnAgentCompletion,
            isWatching: isWatching()) else { return }
        let session = workspaceID.flatMap { ShellWorkspace.Registry.stores[$0]?.workspaceTitle }
        let message = AgentCompletionPolicy.turnMessage(agent: end.agent,
                                                        duration: end.duration,
                                                        session: session)
        announce(message.title, message.body, workspaceID, end.paneID)
    }

    func update(to count: Int) {
        guard count != runningCount else { return }
        runningCount = count
        SleepGuard.shared.agentsRunningChanged(to: count)
        applyDockBadge(count)
        MenuBarItem.shared.update(runningAgents: count)
    }

    /// The dock badge, which is the whole point of counting on a timer: it is what tells
    /// someone who has switched away that the work is still going.
    ///
    /// Cleared to nil rather than set to "0" — a badge reading zero is a badge saying "look
    /// at me" about nothing.
    private func applyDockBadge(_ count: Int) {
        // `NSApplication.shared`, not `NSApp`, and `display()` after setting it: the tile is
        // not ready during launch, and a label set before it is never draws. That is also
        // why this only ever runs from the poll — the first sample lands a second in, by
        // which time the app is up.
        let tile = NSApplication.shared.dockTile
        tile.badgeLabel = count > 0 ? String(count) : nil
        tile.display()
    }
}
