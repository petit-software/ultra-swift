import AppKit
import Foundation

/// Keeps the Mac awake while an agent is working in a pane.
///
/// An agent CLI can run unattended for many minutes with no keyboard or mouse activity, so
/// the machine reaches its idle timeout, sleeps the display and locks — and the user comes
/// back to a password prompt with no idea whether the work finished. Holding a
/// `ProcessInfo` activity for the duration is the documented way to say "something is
/// happening even though nobody is touching this".
///
/// Deliberately NOT `caffeinate` or an `IOPMAssertion` held forever: the assertion is tied
/// to the lifetime of the work, so a crash or a quit releases it. A power assertion that
/// outlives the thing it was protecting is how a laptop ends up flat in a bag.
@MainActor
@Observable
final class SleepGuard {
    static let shared = SleepGuard()

    static let defaultsKey = "ultra.preventSleepWhileAgentRuns"

    /// Held only while `isEnabled` and at least one agent is running.
    private var activity: NSObjectProtocol?
    private(set) var isHolding = false
    private(set) var agentsRunning = 0

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            refresh()
        }
    }

    private init() {
        // Defaults to on: the failure it prevents is silent and annoying, and the cost when
        // no agent is running is exactly nothing, because nothing is held.
        isEnabled = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    /// Called whenever a shell starts or exits.
    func agentsRunningChanged(to count: Int) {
        guard count != agentsRunning else { return }
        agentsRunning = count
        refresh()
    }

    private func refresh() {
        let shouldHold = isEnabled && agentsRunning > 0
        guard shouldHold != isHolding else { return }
        isHolding = shouldHold

        if shouldHold {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
                reason: "An agent is running in a pane")
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// What the settings pane says about the current state, in words rather than a dot.
    var statusDescription: String {
        guard isEnabled else { return "Your Mac sleeps and locks as usual." }
        return switch agentsRunning {
        case 0: "No agent is running — your Mac sleeps as usual."
        case 1: "Holding your Mac awake for 1 running agent."
        default: "Holding your Mac awake for \(agentsRunning) running agents."
        }
    }
}
