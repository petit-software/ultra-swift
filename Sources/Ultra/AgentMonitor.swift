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

    /// Injectable so tests can run the whole transition without a clock or a notification.
    var now: () -> Date = Date.init
    var isWatching: () -> Bool = {
        NSApp?.isActive == true && (NSApp?.windows.contains { $0.isVisible } ?? false)
    }
    var announce: (String, String) -> Void = { title, body in
        AgentCompletionNotifier.shared.notify(title: title, body: body)
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
        for factory in ShellWorkspace.Registry.factories.values {
            present.merge(factory.agentPanes) { first, _ in first }
        }
        observe(present)
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
        announce(message.title, message.body)
    }

    func update(to count: Int) {
        guard count != runningCount else { return }
        runningCount = count
        SleepGuard.shared.agentsRunningChanged(to: count)
        applyDockBadge(count)
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
