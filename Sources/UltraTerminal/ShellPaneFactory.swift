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
    /// `@` or `/` typed at the start of an agent's prompt in a pane — see
    /// `ShellTerminalView.promptTrigger`. Answers whether a picker took the key.
    public var onPromptTrigger: ((PaneID, Character) -> Bool)?

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

    /// Forget what a pane was RESTORED as, so its next build is what was staged and nothing
    /// more. Without this, an agent pane restored from disk and then changed into a plain
    /// shell would see its old record on the rebuild and quietly relaunch the agent.
    public func forget(_ paneID: PaneID) {
        restored.removeValue(forKey: paneID)
    }

    /// Records for panes that do not exist yet, on top of what was restored at launch.
    ///
    /// A layout adopted from another project arrives after this factory was built, with
    /// pane ids nothing has seen before. Without their records here every one of them
    /// would open as a plain shell in the workspace directory, whatever it was meant to be.
    public func adopt(records: [PaneID: PaneRecord]) {
        restored.merge(records) { _, new in new }
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
        view.promptTrigger = { [weak self] character in
            self?.onPromptTrigger?(paneID, character) ?? false
        }
        PromptKeyMonitor.install()
        // Held rather than fed here. A view that has not been laid out yet reports SwiftTerm's
        // default 80 columns, so history written now hard-wraps at 80 and STAYS wrapped once
        // the pane turns out to be wider — the same "no real size yet" problem the deferred
        // start below exists to avoid. It is replayed just before the shell starts, once
        // the pane has its true width.
        //
        // Only a pane being RESTORED gets its history back: a brand new pane has none, and a
        // pane whose id happened to match a file would be showing someone else's session.
        // A shell record can carry a line to type on start in its `tileState` — the
        // demo projects' servers and tails. Typed on EVERY start: the pane is a pane
        // that runs that thing, and the record keeps the line (below) so a relaunch runs
        // it again. Such a pane restores no history either — what it printed last time
        // is what it is about to print, and a stack of "restored" separators over a
        // server's startup is noise.
        let startup = record?.tileState.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        if let startup { startupInput[paneID] = startup }
        if record != nil, startup == nil, let history = scrollback?.load(for: paneID) {
            pendingHistory[paneID] = history
        }
        shells[paneID] = view
        let container = ShellPaneContainer(terminal: view)

        // Started from the view's first real layout, not after a fixed delay. One runloop
        // turn was not always enough: on a fresh window the split tree is still being laid
        // out, the view still reports SwiftTerm's default 80×25, and the PTY was forked at
        // that size — zsh's first prompt was painted for 80 columns, and the stray `%` at
        // the top of a new pane was its end-of-line marker wrapping when the pane turned
        // out narrower. Tests drive `startPendingShells()` directly rather than depending
        // on a layout pass.
        view.onFirstLayout = { [weak self] in self?.startPendingShell(paneID) }

        var fresh = Self.record(for: spec, agent: agent, cwd: cwd)
        fresh.tileState = startup.map { Data($0.utf8) }
        return (container, fresh)
    }

    /// Start any shell that has not started yet. Idempotent.
    public func startPendingShells() {
        for paneID in shells.keys { startPendingShell(paneID) }
        onAgentActivityChange?(runningAgentCount)
    }

    /// Start one pane's shell if it has not started. Idempotent, so the layout that fires
    /// it and a test that calls `startPendingShells()` first cannot fork two.
    ///
    /// Restored history is written just BEFORE the shell starts, so the first prompt lands
    /// underneath it rather than above — and late enough that the pane has its real width.
    private func startPendingShell(_ paneID: PaneID) {
        guard let shell = shells[paneID], !shell.isRunning else { return }
        if let history = pendingHistory.removeValue(forKey: paneID) {
            shell.restore(history: history)
        }
        shell.start()
        onAgentActivityChange?(runningAgentCount)
        // Typed once the prompt is up. A second is longer than any login shell takes to
        // print one, and a line sent before it is read as part of the login, not the prompt.
        if let text = startupInput.removeValue(forKey: paneID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak shell] in
                guard let shell, shell.isRunning else { return }
                shell.inject(text, submit: true)
            }
        }
    }

    /// A line to type and submit in a pane's shell the moment it starts — a dev server, a
    /// log tail — so a pane can open DOING something. Carried in the shell's record, so
    /// every start of that pane runs it. What the demo projects use.
    public var startupInput: [PaneID: String] = [:]

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
        // An agent pane is titled with the agent's NAME — "Claude Code" — rather than
        // its command line: the line is how it was started, and a header reading
        // `claude --model opus --resume` is a header reading a shell history.
        PaneRecord(kind: agent == nil ? .shell : .agent,
                   title: agent.map { AgentDefinition.displayName(forBinary: AgentDefinition(name: "", command: $0).binary) }
                       ?? (cwd.map { abbreviate($0) } ?? "shell"),
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
