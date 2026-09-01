import AppKit
import Foundation
import SwiftTerm
import UltraCore
import UltraDesign
import UltraLayout

/// Builds shell panes for the canvas, and keeps the live ones addressable.
///
/// Deliberately mirrors `PlaceholderPaneFactory`: the canvas asks for content by `PaneID`
/// and gets a view plus a record. It knows nothing about layout, and layout knows nothing
/// about PTYs.
@MainActor
public final class ShellPaneFactory {
    public private(set) var shells: [PaneID: ShellTerminalView] = [:]
    private var restored: [PaneID: PaneRecord]
    private var pendingAgent: AgentDefinition?
    public var theme: TerminalTheme
    public var defaultDirectory: String?
    /// Handed to every shell this factory starts, as `ULTRA_AGENT_SOCK`. An agent finds the
    /// control socket in its environment and nowhere else — that is what makes "only
    /// processes this app spawned can drive it" true rather than aspirational.
    public var agentSocketPath: String?
    /// Called when a pane's title or directory changes, so its header can follow.
    public var onDescriptorChange: ((PaneID, PaneRecord) -> Void)?
    /// Called when a shell starts or exits, with the number of AGENT panes still running.
    /// Drives the keep-awake assertion — see `SleepGuard`.
    public var onAgentActivityChange: ((Int) -> Void)?

    /// Panes running an agent CLI, not plain shells. A plain interactive shell sitting at a
    /// prompt is not work, and holding the machine awake for one would be wrong.
    ///
    /// Counts agents TYPED at a prompt as well as ones this app launched. The launched-as
    /// answer missed every `claude` run in a plain shell, which is how most agents are
    /// actually started — so the machine was free to sleep in the middle of one.
    public var runningAgentCount: Int {
        shells.values.filter(\.isRunningAgent).count
    }

    /// What each live pane is running, for anything that wants to show it.
    public var activityByPane: [PaneID: PaneActivity] {
        shells.compactMapValues { $0.activity }
    }

    /// Everything the sidebar's status badge is derived from, one entry per live pane.
    ///
    /// EVERY pane, not only the ones running an agent. A pane whose agent has just exited
    /// looks exactly like a plain shell in a single sample, and dropping it here would take
    /// the completion with it — see `AgentStatusTracker`, which is stateful for that reason.
    public var agentSamples: [PaneID: AgentPaneSample] {
        shells.mapValues(\.agentSample)
    }

    /// The panes with an agent in them, named.
    ///
    /// The name prefers what the tty reports, because that is what is actually running; a
    /// pane launched as an agent falls back to the command it was launched with, which is
    /// the only name available in the moment between the fork and the exec.
    public var agentPanes: [PaneID: String] {
        shells.compactMapValues { shell in
            guard shell.isRunningAgent else { return nil }
            return shell.activity?.command ?? shell.spec.agentCommand ?? "agent"
        }
    }

    /// Where each pane's history is kept between launches. Nil disables the feature
    /// entirely — which is what tests that are not about scrollback want, so they neither
    /// read the user's real history nor write into it.
    public var scrollback: ScrollbackStore?

    /// History loaded for a pane but not yet written to it — see `startPendingShells()`.
    private var pendingHistory: [PaneID: String] = [:]

    public init(theme: TerminalTheme = .dark,
                defaultDirectory: String? = FileManager.default.currentDirectoryPath,
                restoring records: [PaneID: PaneRecord] = [:],
                scrollback: ScrollbackStore? = nil) {
        self.theme = theme
        self.defaultDirectory = defaultDirectory
        self.restored = records
        self.scrollback = scrollback
    }

    /// The next pane created will run this agent instead of a plain shell. Consumed once —
    /// "New Agent Session" should not turn every later split into an agent.
    public func stageAgent(_ agent: AgentDefinition?) {
        pendingAgent = agent
    }

    public func makeContent(for paneID: PaneID) -> (view: NSView, record: PaneRecord) {
        let record = restored[paneID]
        let agent = pendingAgent?.command ?? record?.command
        pendingAgent = nil

        // A restored pane reopens where it was; a new one opens in the workspace directory.
        let cwd = record?.cwd ?? defaultDirectory
        let spec = ShellSpec(cwd: cwd, agentCommand: agent, theme: theme)
        let view = ShellTerminalView(spec: spec, font: Preferences.terminalFont)
        if let agentSocketPath { view.extraEnvironment["ULTRA_AGENT_SOCK"] = agentSocketPath }
        view.shellDelegate = self
        // Held rather than fed here. A view that has not been laid out yet reports SwiftTerm's
        // default 80 columns, so history written now hard-wraps at 80 and STAYS wrapped once
        // the pane turns out to be wider — the same "no real size yet" problem the deferred
        // start below already exists to avoid. It is replayed from `startPendingShells()`,
        // which runs a runloop turn later with the pane's true width.
        //
        // Only a pane being RESTORED gets its history back: a brand new pane has none, and a
        // pane whose id happened to match a file would be showing someone else's session.
        if record != nil, let history = scrollback?.load(for: paneID) {
            pendingHistory[paneID] = history
        }
        shells[paneID] = view
        let container = ShellPaneContainer(terminal: view)

        // Deferred one runloop turn so the view has a real size first — starting a PTY at
        // 0×0 makes the shell paint its first prompt into a one-column terminal. Tests
        // drive `startPendingShells()` directly rather than depending on a pumped runloop.
        DispatchQueue.main.async { [weak self] in self?.startPendingShells() }

        return (container, Self.record(for: spec, agent: agent, cwd: cwd))
    }

    /// Start any shell that has not started yet. Idempotent.
    ///
    /// Restored history is written just BEFORE the shell starts, so the first prompt lands
    /// underneath it rather than above — and late enough that the pane has its real width.
    public func startPendingShells() {
        for (paneID, shell) in shells where !shell.isRunning {
            if let history = pendingHistory.removeValue(forKey: paneID) {
                shell.restore(history: history)
            }
            shell.start()
        }
        onAgentActivityChange?(runningAgentCount)
    }

    /// A closed pane's history is DISCARDED, not saved.
    ///
    /// Its ID is never issued again, so a saved file could only ever be orphaned — and the
    /// user closing a pane is the clearest statement available that they are done with what
    /// was in it. Keeping it would also mean a "close" that quietly leaves the session's
    /// output on disk, which is not what the word means.
    public func release(_ paneID: PaneID) {
        shells.removeValue(forKey: paneID)?.stop()
        pendingHistory.removeValue(forKey: paneID)
        scrollback?.discard(for: paneID)
        onAgentActivityChange?(runningAgentCount)
    }

    /// Write every live pane's history. Called on termination, where the panes are about to
    /// stop existing and nothing else would capture them.
    public func saveScrollback() {
        guard let scrollback else { return }
        for (paneID, shell) in shells {
            scrollback.save(shell.historyText, for: paneID)
        }
        scrollback.prune(keeping: Set(shells.keys))
    }

    /// Called when a divider drag or window resize commits.
    public func commitResize() {
        for shell in shells.values { shell.commitPendingResize() }
    }

    /// Push the current font to every live shell and re-tell each PTY its size.
    ///
    /// The grid is measured from the font, so a size change moves every cell boundary —
    /// without the authoritative resize the shell keeps drawing to the old rows and columns.
    public func applyFont() {
        let font = Preferences.terminalFont
        for shell in shells.values where shell.font != font {
            shell.font = font
            shell.commitPendingResize()
        }
    }

    /// Push the renderer preference to every live shell.
    public func applyRenderer() {
        for shell in shells.values { shell.wantsMetalRenderer = Preferences.useMetalRenderer }
    }

    public func apply(theme: TerminalTheme) {
        self.theme = theme
        for shell in shells.values { shell.apply(theme: theme) }
    }

    /// Type text into a pane's prompt without submitting it.
    public func inject(_ text: String, into paneID: PaneID, submit: Bool = false) {
        shells[paneID]?.inject(text, submit: submit)
    }

    public static func record(for spec: ShellSpec, agent: String?, cwd: String?) -> PaneRecord {
        // A shell pane is identified by WHERE IT IS. The folder name alone is ambiguous
        // across checkouts, and name-plus-path said the same thing twice, so the header
        // carries the path and nothing else. An agent pane still says which agent it runs.
        PaneRecord(kind: .shell,
                   title: agent ?? (cwd.map { abbreviate($0) } ?? "shell"),
                   subtitle: agent == nil ? nil : cwd.map { abbreviate($0) },
                   icon: agent == nil ? "apple.terminal" : "sparkles",
                   cwd: cwd,
                   command: agent)
    }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension ShellPaneFactory: ShellTerminalViewDelegate {
    public func shellTitleChanged(_ view: ShellTerminalView, title: String) {
        guard let paneID = shells.first(where: { $0.value === view })?.key,
              !title.isEmpty else { return }
        var record = Self.record(for: view.spec, agent: view.spec.agentCommand, cwd: view.spec.cwd)
        record.title = title
        onDescriptorChange?(paneID, record)
    }

    public func shellDirectoryChanged(_ view: ShellTerminalView, directory: String?) {
        guard let paneID = shells.first(where: { $0.value === view })?.key else { return }
        onDescriptorChange?(paneID,
                            Self.record(for: view.spec, agent: view.spec.agentCommand,
                                        cwd: directory ?? view.spec.cwd))
    }

    public func shellTerminated(_ view: ShellTerminalView, exitCode: Int32?) {
        // The pane stays: a user who typed `exit` by accident should still see the
        // scrollback, and closing the pane is their call, not ours.
        let message = exitCode.map { "[process exited with code \($0)]" } ?? "[process exited]"
        view.feed(text: "\r\n\u{1b}[2m\(message)\u{1b}[0m\r\n")
        // An agent that has finished must stop holding the machine awake.
        onAgentActivityChange?(runningAgentCount)
    }
}
