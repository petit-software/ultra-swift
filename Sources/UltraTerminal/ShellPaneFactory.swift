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
    private var containers: [PaneID: ShellPaneContainer] = [:]
    private var restored: [PaneID: PaneRecord]
    private var pendingAgent: AgentDefinition?
    public var theme: TerminalTheme
    public var defaultDirectory: String?
    /// Called when a pane's title or directory changes, so its header can follow.
    public var onDescriptorChange: ((PaneID, PaneRecord) -> Void)?

    public init(theme: TerminalTheme = .dark,
                defaultDirectory: String? = FileManager.default.currentDirectoryPath,
                restoring records: [PaneID: PaneRecord] = [:]) {
        self.theme = theme
        self.defaultDirectory = defaultDirectory
        self.restored = records
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
        let view = ShellTerminalView(spec: spec)
        view.shellDelegate = self
        shells[paneID] = view
        let container = ShellPaneContainer(terminal: view)
        containers[paneID] = container

        // Deferred one runloop turn so the view has a real size first — starting a PTY at
        // 0×0 makes the shell paint its first prompt into a one-column terminal. Tests
        // drive `startPendingShells()` directly rather than depending on a pumped runloop.
        DispatchQueue.main.async { [weak self] in self?.startPendingShells() }

        return (container, Self.record(for: spec, agent: agent, cwd: cwd))
    }

    /// Start any shell that has not started yet. Idempotent.
    public func startPendingShells() {
        for shell in shells.values where !shell.isRunning { shell.start() }
    }

    public func release(_ paneID: PaneID) {
        containers.removeValue(forKey: paneID)
        shells.removeValue(forKey: paneID)?.stop()
    }

    /// Called when a divider drag or window resize commits.
    public func commitResize() {
        for shell in shells.values { shell.commitPendingResize() }
    }

    public func apply(theme: TerminalTheme) {
        self.theme = theme
        for shell in shells.values { shell.apply(theme: theme) }
        for container in containers.values { container.applyBackground() }
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
    }
}
