import AppKit
import Foundation
import SwiftTerm
import UltraDesign

/// How a shell pane was started, and where.
public struct ShellSpec: Equatable, Sendable {
    public var cwd: String?
    /// The agent command line, or nil for a plain interactive shell.
    public var agentCommand: String?
    public var theme: TerminalTheme

    public init(cwd: String? = nil, agentCommand: String? = nil, theme: TerminalTheme = .dark) {
        self.cwd = cwd
        self.agentCommand = agentCommand
        self.theme = theme
    }
}

@MainActor
public protocol ShellTerminalViewDelegate: AnyObject {
    func shellTitleChanged(_ view: ShellTerminalView, title: String)
    func shellDirectoryChanged(_ view: ShellTerminalView, directory: String?)
    func shellTerminated(_ view: ShellTerminalView, exitCode: Int32?)
}

/// A terminal pane backed by a real PTY.
///
/// This deliberately does NOT use SwiftTerm's `LocalProcessTerminalView`. That class resizes
/// the PTY the instant the view's grid changes, and its `sizeChanged` is `public` rather than
/// `open`, so the policy cannot be overridden from outside the module. Owning the
/// `LocalProcess` directly is ~60 lines and buys the coalescing the product depends on:
/// frames follow the cursor every event, `SIGWINCH` does not. See docs/01-SPLIT-ENGINE.md § 6.
///
/// It is also the seam the plan already called for — depending on `TerminalView` and
/// `Terminal` through our own type is what leaves a path to a custom renderer later.
@MainActor
public final class ShellTerminalView: TerminalView, @preconcurrency TerminalViewDelegate,
                                      @preconcurrency LocalProcessDelegate {
    public weak var shellDelegate: ShellTerminalViewDelegate?
    public private(set) var spec: ShellSpec
    /// Nil until the process starts; nil again once it exits.
    public private(set) var processID: pid_t?
    public private(set) var isRunning = false

    private var process: LocalProcess!
    private var coalescer = ResizeCoalescer()
    private var pendingFinalResize: DispatchWorkItem?

    public init(spec: ShellSpec, font: NSFont? = nil) {
        self.spec = spec
        super.init(frame: .zero, font: font)
        // Pin the scroller to overlay. SwiftTerm defaults to `.overlay`, but a user with
        // "Show scroll bars: Always" in System Settings gets `.legacy` system-wide, which
        // takes permanent width out of every pane and puts a grey track down each one.
        // A terminal's scrollback is navigated by keyboard and wheel, not by a visible bar.
        scrollerStyle = .overlay
        terminalDelegate = self
        process = LocalProcess(delegate: self)
        apply(theme: spec.theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Lifecycle

    /// Start the shell. Safe to call once; a second call is ignored rather than orphaning
    /// the first process.
    public func start() {
        guard !isRunning else { return }
        let shell = ShellLauncher.loginShell()
        let arguments = ShellLauncher.arguments(runningAgent: spec.agentCommand)
        // A cwd that no longer exists is reported, never silently swapped for $HOME.
        let directory = ShellLauncher.validatedDirectory(spec.cwd)
        if spec.cwd != nil, directory == nil {
            feed(text: "\r\n\u{1b}[31mWorking directory is gone:\u{1b}[0m \(spec.cwd ?? "")\r\n")
        }
        isRunning = true
        process.startProcess(executable: shell, args: arguments, currentDirectory: directory)
        processID = process.shellPid
    }

    public func stop() {
        pendingFinalResize?.cancel()
        guard isRunning else { return }
        process.terminate()
        isRunning = false
    }

    /// Type text at the prompt. `submit: false` leaves it there so the user can add to it —
    /// that is the whole point of the Context and Todo tiles' "send to shell".
    public func inject(_ text: String, submit: Bool = false) {
        let payload = Array((submit ? text + "\r" : text).utf8)
        send(source: self, data: payload[...])
    }

    public func apply(theme: TerminalTheme) {
        spec.theme = theme
        TerminalPalette.apply(theme, to: self)
        needsDisplay = true
    }

    // MARK: - Resize policy

    public override func layout() {
        super.layout()
        hideScroller()
        scheduleResize(isFinal: false)
    }

    /// SwiftTerm owns its `NSScroller` privately, so it is reached through the view tree
    /// rather than a property. `.overlay` already reserves no width, so hiding it costs the
    /// pane no columns — a shell's scrollback is navigated by wheel and keyboard.
    private func hideScroller() {
        for case let scroller as NSScroller in subviews where !scroller.isHidden {
            scroller.isHidden = true
        }
    }

    /// Called when a divider drag commits or a window resize ends: the shell must not be
    /// left holding a stale size, so this always gets through.
    public func commitPendingResize() {
        pendingFinalResize?.cancel()
        // Slightly after the commit, matching the 50ms the spec calls for: it lets the
        // final layout pass settle before the authoritative size is sent.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scheduleResize(isFinal: true) }
        }
        pendingFinalResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func scheduleResize(isFinal: Bool) {
        guard isRunning else { return }
        let grid = ResizeCoalescer.Grid(cols: getTerminal().cols, rows: getTerminal().rows)
        guard coalescer.shouldSend(grid, at: ProcessInfo.processInfo.systemUptime,
                                   isFinal: isFinal) else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    // MARK: - TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        scheduleResize(isFinal: false)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        shellDelegate?.shellTitleChanged(self, title: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        spec.cwd = directory ?? spec.cwd
        shellDelegate?.shellDirectoryChanged(self, directory: directory)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    public func bell(source: TerminalView) { NSSound.beep() }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }

    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    // MARK: - LocalProcessDelegate
    //
    // `LocalProcess` posts these on `DispatchQueue.main` by default, so main-actor
    // isolation is accurate rather than assumed. It also has to be SYNCHRONOUS: hopping
    // `dataReceived` onto a Task would reorder the byte stream, and a terminal that
    // reorders its own output is worse than one that blocks.

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        isRunning = false
        processID = nil
        shellDelegate?.shellTerminated(self, exitCode: exitCode)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        feed(byteArray: slice)
    }

    public func getWindowSize() -> winsize {
        let frame = getOptimalFrameSize()
        let terminal = getTerminal()
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
                       ws_xpixel: UInt16(frame.width), ws_ypixel: UInt16(frame.height))
    }
}
