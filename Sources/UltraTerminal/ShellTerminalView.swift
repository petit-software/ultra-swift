import AppKit
import Foundation
import SwiftTerm
import UltraCore
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

    /// What this pane is running RIGHT NOW, read from the tty's foreground process group.
    ///
    /// Deliberately not cached: it changes whenever the user runs anything, and a stale
    /// answer is worse than the syscall it saves. Nil once the shell has exited.
    public var activity: PaneActivity? {
        guard isRunning else { return nil }
        return ForegroundProcess.activity(ofTerminal: process.childfd)
    }

    /// Is an agent running in this pane?
    ///
    /// Two sources, ORed, because they answer for two different ways of starting one and
    /// neither covers the other:
    ///
    /// - **Launched as an agent.** `ShellLauncher` runs `-l -c "exec <command>"`, so the
    ///   pane's process IS the agent rather than a shell wrapping it. It therefore cannot
    ///   outlive its agent: when the agent exits the process exits, `isRunning` goes false,
    ///   and this goes false with it. No tty reading needed, and none that could race with
    ///   the exec while the agent is starting.
    /// - **Typed at a prompt.** `claude` run in a plain interactive shell — how most agents
    ///   are actually started, and completely invisible to what the app recorded at launch.
    ///   The tty sees it, and sees it exit back to the prompt.
    ///
    /// The launched half is deliberately NOT gated on the tty agreeing. A user's own agent
    /// need not be one of the built-ins, and demanding the foreground process match a known
    /// binary would stop counting every agent they configured themselves.
    public var isRunningAgent: Bool { isRunningAgent(given: activity) }

    /// The same rule, answered from a reading already taken. One rule, two callers: the
    /// property above for anyone who just wants the answer, and `agentSample`, which must
    /// not read the tty twice — see there.
    func isRunningAgent(given activity: PaneActivity?) -> Bool {
        guard isRunning else { return false }
        return spec.agentCommand != nil || (activity?.isAgent ?? false)
    }
    public private(set) var isRunning = false

    /// When this pane last produced a byte, and when it last rang `BEL`.
    ///
    /// Both exist for `AgentStatus`, which has no other way to tell an agent that is
    /// thinking from one that has stopped and is waiting for a human — see
    /// `AgentStatusTracker`. Recorded here rather than sampled because output is an EVENT
    /// and a poller would only ever see the gaps between bursts.
    public private(set) var lastOutputAt: Date?
    public private(set) var lastBellAt: Date?
    /// When the person last typed into this pane, or a tile sent into it. The burst that
    /// follows is the TUI redrawing what they typed, not the agent at work — see
    /// `AgentEcho` — and does not move `lastOutputAt`.
    private var lastInputAt: Date?

    /// What the pane's process exited with, kept after it has gone.
    ///
    /// Only meaningful for a pane launched AS an agent — `ShellLauncher` runs `exec
    /// <agent>`, so the code is the agent's own. A plain shell's code is the shell's, and an
    /// agent typed at a prompt is reaped by that shell and never reaches this at all.
    public private(set) var lastExitCode: Int32?

    /// The title as the agent in this pane last set it, raw; nil once the agent has gone.
    private var agentTitle: String?

    /// Everything `AgentStatus` is allowed to read from this pane, sampled together.
    ///
    /// One value rather than four properties, because the rules read across the fields and a
    /// sample whose "is an agent running" is a tick newer than its "has it gone quiet"
    /// cannot be reasoned about.
    ///
    /// The tty is read ONCE. Asking `isRunningAgent` and then `activity` takes two separate
    /// readings of the foreground process group, which is both twice the syscalls on a
    /// per-second poll and — the part that matters — two answers from two instants in a
    /// value whose whole purpose is to be self-consistent.
    public var agentSample: AgentPaneSample {
        let activity = activity
        let isAgent = isRunningAgent(given: activity)
        // The agent has gone, and its title with it: the next one starts unnamed.
        if !isAgent { agentTitle = nil }
        let agent = isAgent
            ? ((activity?.isAgent == true ? activity?.command : nil)
               ?? spec.agentCommand.map { AgentDefinition(name: "", command: $0).binaryName }
               ?? "agent")
            : nil
        return AgentPaneSample(
            // The `"agent"` fallback cannot currently be reached — a pane is only running an
            // agent because it was launched as one or because the tty named one — but a
            // sample that reported nil here would read as an agent EXITING, so the
            // unreachable branch is the one worth being explicit about.
            // The tty's name when it IS an agent's; else the configured command's binary —
            // a pane launched as `python3 agent.py` is reported as that, not as "Python".
            agent: agent,
            lastOutputAt: lastOutputAt,
            lastBellAt: lastBellAt,
            screen: isAgent ? screenTail(AgentPrompt.lines) : [],
            title: AgentTitle.active(agentTitle,
                                     agentName: agent.map { AgentDefinition.displayName(forBinary: $0) }))
    }

    /// The last `count` rows of the screen as text. The rows on view: scrolled up into
    /// the history, it is the history — and someone scrolled up there is reading the pane
    /// already. Trailing blank rows are dropped, so the bottom is where the text ends.
    public func screenTail(_ count: Int) -> [String] {
        let terminal = getTerminal()
        var lines: [String] = []
        for row in max(0, terminal.rows - count - 6)..<terminal.rows {
            lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// Run once, from the first layout pass that gives the view a real size, then dropped.
    ///
    /// The shell is forked from here rather than on a timer. A PTY opened before the pane
    /// has its width is opened at SwiftTerm's default 80 columns, and zsh paints its first
    /// prompt for that width: the stray `%` at the top of a new pane was PROMPT_SP's
    /// end-of-line marker, written for 80 columns and wrapping once the pane turned out
    /// narrower, and the doubled prompt under it was zsh redrawing on the size change.
    public var onFirstLayout: (() -> Void)?

    private var process: LocalProcess!
    private var coalescer = ResizeCoalescer()
    private var pendingFinalResize: DispatchWorkItem?
    private var pendingDirectoryProbe: DispatchWorkItem?

    /// Extra environment for the spawned shell, on top of the login shell's own.
    public var extraEnvironment: [String: String] = [:]

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
        // Files from the Finder land as their paths — see `performDragOperation`.
        registerForDraggedTypes([.fileURL])
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
        // `environment: nil` would inherit ours; passing an explicit list is the only way to
        // add to it, so the current environment is rebuilt with our additions on top.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        let encoded = environment.map { "\($0.key)=\($0.value)" }
        process.startProcess(executable: shell, args: arguments,
                             environment: encoded, currentDirectory: directory)
        processID = process.shellPid
    }

    public func stop() {
        pendingFinalResize?.cancel()
        pendingDirectoryProbe?.cancel()
        pendingDirectoryProbe = nil
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

    // MARK: - Dropped files

    /// A file dragged from the Finder, or from the file tree, lands in the shell as its
    /// path, typed at the prompt and not submitted — the point of dropping an image on an
    /// agent's pane is to put the path where a prompt about it is being written.
    ///
    /// Files ONLY. A pane being dragged across the canvas carries its own type, and the
    /// canvas is the view that takes that; by claiming nothing but file URLs this view is
    /// passed over for everything else, so a pane dropped onto a shell still moves the
    /// pane. The keyboard path is the one the Context tile already has — "send to shell"
    /// types the same path — and the path itself can always be typed.
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedPaths(from: sender).isEmpty || !isRunning ? [] : .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.droppedPaths(from: sender)
        guard isRunning, !paths.isEmpty else { return false }
        inject(ShellQuote.line(paths))
        return true
    }

    /// The file paths on a drag's pasteboard, in the order they were picked up.
    static func droppedPaths(from sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true])
        return (urls as? [URL] ?? []).map(\.path)
    }

    // MARK: - Scrollback

    /// This pane's history as plain text, for `ScrollbackStore`.
    ///
    /// The NORMAL buffer, never the active one: a pane sitting in `vim` or `less` has the
    /// ALT buffer up, which is a scratch screen with no scrollback and is gone the moment the
    /// program exits. Saving it would restore a snapshot of a full-screen app the user is no
    /// longer in, with the actual session history — the thing they wanted — thrown away.
    public var historyText: String {
        String(decoding: getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
    }

    /// Show restored history above the live session.
    ///
    /// Written dimmed and under a rule, because restored text is NOT this session: the
    /// commands in it did not run in this shell, and a user scrolling up needs to be able to
    /// tell where the boundary is before they trust what they are reading. It is also the
    /// only honest way to present it — the processes are gone, the exit codes are gone, and
    /// nothing above the rule can be re-run by pressing up.
    ///
    /// Fed before the shell starts, so its first prompt lands underneath.
    public func restore(history: String) {
        let text = history.hasSuffix("\n") ? String(history.dropLast()) : history
        guard !text.isEmpty else { return }
        // The rule's own escape sequences are OURS, not the file's — `ScrollbackStore` has
        // already stripped every control byte from `text`, so nothing in it can reach here.
        feed(text: "\u{1b}[2m" + text.replacingOccurrences(of: "\n", with: "\r\n")
             + "\r\n\u{1b}[2m\u{2500}\u{2500} restored \u{2500}\u{2500}\u{1b}[0m\r\n")
    }

    public func apply(theme: TerminalTheme) {
        let wasDark = spec.theme.isDark
        spec.theme = theme
        TerminalPalette.apply(theme, to: self)
        // What is already on screen and in the scrollback was washed, or left alone, for
        // the theme on its way out.
        backgroundWasher.themeChanged(theme, in: getTerminal())
        // A light theme draws through CoreGraphics: see `drawsOnGPU`.
        applyRenderer()
        needsDisplay = true
        // AFTER the palette, so the OSC 11 the program sends back on hearing this is
        // answered with the new background and not the one on its way out.
        if theme.isDark != wasDark, notifiesColorScheme { reportColorScheme() }
    }

    /// Keeps the pane's text readable on a surface a program drew for another theme. See
    /// `LegibleBackgrounds`.
    private lazy var backgroundWasher = BackgroundWasher(theme: spec.theme)

    // MARK: - Colour scheme reports

    /// Whether the program in this pane asked to hear when the pane turns light or dark
    /// (`CSI ? 2031 h`). See `ColorSchemeReports`.
    public private(set) var notifiesColorScheme = false
    private var colorSchemeScanner = ColorSchemeReports.Scanner()

    /// Where a report is written. The PTY, except in a test, which has no process to
    /// write to and wants to read what would have been sent.
    var colorSchemeReportSink: (([UInt8]) -> Void)?

    private func reportColorScheme() {
        let report = ColorSchemeReports.report(isDark: spec.theme.isDark)
        if let colorSchemeReportSink { colorSchemeReportSink(report); return }
        guard isRunning else { return }
        // Through `send`, so it counts as input: the repaint a program answers it with is
        // then an echo, and does not light the pane up as an agent that started working.
        send(source: self, data: report[...])
    }

    /// Read what the program asked for out of its output. Internal for the tests.
    func noteColorSchemeRequests<Bytes: Sequence>(in bytes: Bytes) where Bytes.Element == UInt8 {
        for request in colorSchemeScanner.scan(bytes) {
            switch request {
            case .notify(let wanted): notifiesColorScheme = wanted
            case .query: reportColorScheme()
            }
        }
    }

    // MARK: - Renderer

    /// Whether this pane SHOULD be drawing on the GPU. The actual state is
    /// `isUsingMetalRenderer`, and the two differ when Metal was asked for and refused.
    public var wantsMetalRenderer = Preferences.useMetalRenderer {
        didSet { guard wantsMetalRenderer != oldValue else { return }; applyRenderer() }
    }

    /// Set once a fallback has been reported, so a pane that cannot do Metal says so a single
    /// time rather than on every layout pass.
    private var hasReportedMetalFailure = false

    /// SwiftTerm requires the view to be in a window before Metal can be turned on — the
    /// renderer binds to the window's screen to pick a scale factor. Applying here as well as
    /// on the preference change is what makes the setting work for panes that do not exist
    /// yet when it is flipped.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRenderer()
    }

    /// Whether the GPU renderer is the one to use right now: asked for, and on a dark theme.
    ///
    /// SwiftTerm's Metal renderer clears its drawable to the background's RGB at the
    /// background's alpha, unpremultiplied, into a layer that composites premultiplied.
    /// The cells here paint no background (`TerminalPalette.apply`), so the alpha is zero
    /// and the RGB is ADDED to whatever is behind the pane. On a dark theme that is a few
    /// percent of grey and nobody sees it. On a light one it is white: every glyph's
    /// antialiased edge blends towards white-plus-the-pane instead of the pane, so the
    /// edge is burnt away — black text comes out thin, and dim or coloured text, which
    /// has little but edge at this size, is eaten down to an outline. CoreGraphics draws
    /// onto a truly clear layer, so a light theme is drawn there until the clear colour
    /// is premultiplied upstream.
    private var drawsOnGPU: Bool { wantsMetalRenderer && spec.theme.isDark }

    /// Bring the renderer in line with `wantsMetalRenderer`.
    ///
    /// A refusal is REPORTED, not swallowed. `setUseMetal` throws when there is no Metal
    /// device or the pipeline will not build, and a pane that silently stayed on
    /// CoreGraphics would leave the user with a setting that is on and doing nothing —
    /// they would have no way to tell that from Metal simply not being faster.
    public func applyRenderer() {
        guard window != nil else { return }
        guard drawsOnGPU != isUsingMetalRenderer else { return }
        do {
            try setUseMetal(drawsOnGPU)
        } catch {
            guard wantsMetalRenderer, !hasReportedMetalFailure else { return }
            hasReportedMetalFailure = true
            feed(text: "\r\n\u{1b}[2m[GPU rendering unavailable: \(error)"
                 + " — using CoreGraphics]\u{1b}[0m\r\n")
        }
    }

    // MARK: - Resize policy

    public override func layout() {
        super.layout()
        hideScroller()
        // SwiftTerm has already resized its grid in `setFrameSize`, so a shell started
        // here is forked at the columns and rows the pane really has.
        if let onFirstLayout, bounds.width > 0, bounds.height > 0 {
            self.onFirstLayout = nil
            onFirstLayout()
        }
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
        // Kept only when an agent set it: a shell's prompt titles the pane too, and that
        // is the folder, not what an agent is doing.
        agentTitle = isRunningAgent ? title : nil
        shellDelegate?.shellTitleChanged(self, title: title)
    }

    /// OSC 7. The shell reports a `file://host/path` URL, not a path — see
    /// `ShellLauncher.localPath(fromHostDirectory:)`. A report we cannot turn into a local
    /// path (a shell ssh'd to another machine, say) leaves the last known directory alone
    /// rather than overwriting it with something that does not exist here.
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let path = ShellLauncher.localPath(fromHostDirectory: directory) else { return }
        guard path != spec.cwd else { return }
        spec.cwd = path
        shellDelegate?.shellDirectoryChanged(self, directory: path)
    }

    /// Ask the kernel where the shell is, because it will not tell us itself.
    ///
    /// `hostCurrentDirectoryUpdate` above is the right channel and it never fires on a stock
    /// macOS — see `ForegroundProcess.workingDirectory(ofProcess:)` for why. This is the
    /// fallback that makes a pane's header true: it reads the same fact from the kernel and
    /// hands it to the same delegate, so headers, tabs, "Follow Shell", and what a restored
    /// pane reopens in all follow a `cd` without the shell's cooperation.
    ///
    /// Driven by OUTPUT rather than by a timer. A directory only changes because the shell
    /// did something, and anything the shell does reprints a prompt — so arriving output is
    /// exactly when there is a new answer to read, and an idle pane costs nothing at all.
    ///
    /// Output arrives in bursts, and a burst is not a burst of `cd`s. A probe already
    /// scheduled is therefore LEFT ALONE rather than pushed back: one syscall per 0.15s of
    /// noisy output, and one allocation to schedule it, instead of one of each per chunk on
    /// the path that carries every byte the terminal ever draws. Leaving it also means a
    /// script that cd's while printing is still followed, which resetting the timer on every
    /// chunk would have postponed until the output stopped.
    private func scheduleDirectoryProbe() {
        guard pendingDirectoryProbe == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.probeDirectory() }
        pendingDirectoryProbe = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Driven directly by tests, which do not own a pumped runloop for the debounce above.
    func probeDirectory() {
        pendingDirectoryProbe = nil
        guard isRunning, let processID,
              let path = ForegroundProcess.workingDirectory(ofProcess: processID) else { return }
        // Compared canonically, and only compared. The kernel answers with the fully resolved
        // path, so a pane opened at `/tmp/x` or through any symlinked project root would
        // otherwise report a move on its very first prompt and rewrite its own header into a
        // spelling the user never typed. The pane has not gone anywhere; it is the same
        // directory said a different way.
        guard WorkspaceDocument.canonical(path)
                != spec.cwd.map(WorkspaceDocument.canonical) else { return }
        spec.cwd = path
        shellDelegate?.shellDirectoryChanged(self, directory: path)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        lastInputAt = Date()
        process.send(data: data)
    }

    // MARK: - Prompt menus

    /// The characters that open a picker at an agent's prompt instead of being typed:
    /// `@` for a file, `/` for a command. See `promptTrigger`.
    public static let promptTriggers: Set<Character> = ["@", "/"]

    /// Asked when one of `promptTriggers` is typed as the first character of a line while
    /// an agent owns the tty. Answering true means the picker took the key and the
    /// terminal sends nothing; false, or no handler, and the character goes through as
    /// typed. Never asked in a plain shell, or mid-line: a plain key is the shell's, and
    /// this is the one narrow case where it is not — see `PromptInput`.
    public var promptTrigger: ((Character) -> Bool)?

    /// Whether the caret is at the start of a line: nothing drawn before it on its row but
    /// the agent's prompt marker — see `PromptInput.isLineStart`.
    ///
    /// SwiftTerm hands out rows of the DISPLAYED screen, which is the live one only when
    /// the view is at the bottom. Scrolled up into the history, the view is brought back
    /// down first — which is what a typed key does anyway, so this changes nothing the
    /// user would not see from the key itself.
    public var caretIsAtLineStart: Bool {
        guard let terminal else { return false }
        if canScroll, scrollPosition < 1 { scroll(toPosition: 1) }
        guard let line = terminal.getLine(row: terminal.buffer.y) else { return false }
        return PromptInput.isLineStart(before: line.translateToString(trimRight: false, startCol: 0, endCol: terminal.buffer.x))
    }

    /// Whether a key event is a trigger this view's picker takes, asked by
    /// `PromptKeyMonitor` before the event reaches `keyDown` — SwiftTerm's `keyDown` is
    /// not overridable from outside its module, and a local event monitor sees the key
    /// first anyway. True means the handler showed its picker and the key is consumed.
    public func handlesPromptKey(_ event: NSEvent) -> Bool {
        guard promptTrigger != nil, isRunningAgent, caretIsAtLineStart,
              let characters = event.characters, characters.count == 1,
              let character = characters.first, Self.promptTriggers.contains(character),
              // ⇧ is how `@` is typed; anything else is a chord, and a chord is not a character.
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift).isEmpty
        else { return false }
        return promptTrigger?(character) == true
    }

    /// Where the caret is, in this view's coordinates: the cell the next character lands
    /// in. For a picker to open beside. SwiftTerm keeps its caret view to itself, so the
    /// cell is computed from the grid: the view's size over its columns and rows.
    public var caretRect: CGRect {
        guard let terminal, terminal.cols > 0, terminal.rows > 0 else { return .zero }
        let width = bounds.width / CGFloat(terminal.cols)
        let height = bounds.height / CGFloat(terminal.rows)
        let column = CGFloat(terminal.buffer.x)
        let row = CGFloat(terminal.buffer.y)
        let y = isFlipped ? row * height : bounds.height - (row + 1) * height
        return CGRect(x: column * width, y: y, width: width, height: height)
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    /// Silent unless the user has asked for it — see `Preferences.audibleBell`.
    ///
    /// Read live rather than cached: a shell can ring at any moment, and a bell that stays
    /// audible until the pane is restarted is not what unticking a box means.
    ///
    /// Rate-limited through `TerminalBell` rather than beeping straight from here. An agent
    /// rings `BEL` many times a minute, and one `NSSound.beep()` per ring is one CoreAudio
    /// stream opened and torn down per ring.
    public func bell(source: TerminalView) {
        // Recorded BEFORE the preference is consulted. A bell is how an agent says it wants
        // attention, and the sidebar's status badge depends on hearing every one of them —
        // whether or not the user has asked to hear them too.
        lastBellAt = Date()
        guard Preferences.audibleBell else { return }
        TerminalBell.ring()
    }

    /// Show a clicked link in a pane — a page in the browser pane, a file in the editor —
    /// and answer whether it could. False, or nil, and it goes to the Mac instead.
    public var openLink: ((LinkTarget) -> Bool)?
    /// Whether `openLink` could show this link now: a pane to show it in, or room for one.
    /// The menu's "Open in Ultra" dims when it could not.
    public var canOpenLink: ((LinkTarget) -> Bool)?

    /// A ⌘-click on a URL, an OSC 8 hyperlink, or a file path. SwiftTerm finds all three.
    ///
    /// By default it asks, with a menu at the pointer: open it in Ultra, or in the browser
    /// or Finder. The setting can make a click do either straight away, and ⌥⌘-click always
    /// goes to the Mac — see `TerminalLinkMenu.clickAction`.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // The click that got here: `mouseUp` calls this synchronously, so the current
        // event is that click, with the modifiers held during it and where it landed.
        let event = NSApp.currentEvent
        guard let target = Self.linkTarget(link, cwd: spec.cwd) else {
            // A path that is not there — any more, or relative to somewhere other than the
            // shell's directory. Silence would read as a missed click.
            let scheme = URL(string: link)?.scheme?.lowercased()
            if scheme == nil || scheme == "file" { NSSound.beep() }
            return
        }
        if let action = TerminalLinkMenu.clickAction(for: target,
                                                     modifiers: event?.modifierFlags ?? [],
                                                     preference: Preferences.linkClick) {
            perform(action, on: target)
            return
        }
        let point = event.map { convert($0.locationInWindow, from: nil) }
            ?? NSPoint(x: bounds.midX, y: bounds.midY)
        ChromeMenuPresenter.popUp(linkMenu(for: target), at: point, in: self)
    }

    /// The link menu's rows for this pane: "Open in Ultra" dimmed with nowhere to open.
    func linkMenu(for target: LinkTarget) -> [ChromeMenuEntry] {
        let canOpen = canOpenLink?(target) ?? false
        let app: String? = if case .file(let url) = target {
            TerminalLinkMenu.defaultAppName(for: url)
        } else {
            nil
        }
        return TerminalLinkMenu.actions(for: target).map { action in
            guard let action else { return .separator }
            return .item(title: TerminalLinkMenu.title(of: action, for: target, defaultApp: app),
                         symbol: TerminalLinkMenu.symbol(of: action),
                         isEnabled: action != .openInUltra || canOpen) { [weak self] in
                self?.perform(action, on: target)
            }
        }
    }

    func perform(_ action: LinkAction, on target: LinkTarget) {
        switch action {
        case .openInUltra:
            if openLink?(target) == true { return }
            perform(TerminalLinkMenu.fallback(for: target), on: target)
        case .openInBrowser, .openWithDefaultApp:
            NSWorkspace.shared.open(target.url)
        case .showInFinder:
            if case .folder(let url) = target {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([target.url])
            }
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target.isWeb ? target.url.absoluteString : target.url.path,
                                           forType: .string)
        }
    }

    /// What a clicked link is: a file or folder that exists, a web page, or nothing that
    /// opens. A file wins over a web reading of the same text.
    nonisolated public static func linkTarget(_ link: String, cwd: String?) -> LinkTarget? {
        if let file = fileLink(link, cwd: cwd) {
            return isPlainFolder(file) ? .folder(file) : .file(file)
        }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return .web(url)
    }

    /// The file a clicked link names, if it names one that exists.
    ///
    /// SwiftTerm hands over a `file:` URL as a URL, and a path it spotted in the text —
    /// `/abs`, `~/x`, `./x`, `../x`, `Sources/a.swift` — as the bare text. A relative path is
    /// the shell's: resolved against the directory the pane is in now, which is where
    /// `ls` or a compiler printed it from. A compiler's `a.swift:12:4` names `a.swift`.
    /// Anything else, or a file that is not there, is nil.
    nonisolated public static func fileLink(_ link: String, cwd: String?,
                                            fileManager: FileManager = .default) -> URL? {
        let text = link.trimmingCharacters(in: .whitespaces)
        let path: String
        if let url = URL(string: text), let scheme = url.scheme {
            guard scheme.lowercased() == "file", url.isFileURL else { return nil }
            path = url.path(percentEncoded: false)
        } else {
            let expanded = NSString(string: text).expandingTildeInPath
            if expanded.hasPrefix("/") {
                path = expanded
            } else if let cwd {
                path = NSString(string: cwd).appendingPathComponent(expanded)
            } else {
                return nil
            }
        }
        var candidates = [path]
        if let location = path.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) {
            candidates.append(String(path[..<location.lowerBound]))
        }
        guard let found = candidates.first(where: { fileManager.fileExists(atPath: $0) })
        else { return nil }
        return URL(fileURLWithPath: found).standardizedFileURL
    }

    nonisolated static func isPlainFolder(_ file: URL) -> Bool {
        let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
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
        pendingDirectoryProbe?.cancel()
        pendingDirectoryProbe = nil
        isRunning = false
        processID = nil
        // Whoever subscribed is gone, and the next program in this pane did not ask.
        notifiesColorScheme = false
        colorSchemeScanner = ColorSchemeReports.Scanner()
        // SwiftTerm passes the raw `waitpid` status; everything past here wants the code.
        let code = exitCode.flatMap(ShellLauncher.exitCode(fromWaitStatus:))
        // A process killed by a signal reports no code at all. Treated as a failure rather
        // than as a clean finish: an agent that was terminated did not complete its work,
        // and a green row would say it had.
        lastExitCode = code ?? -1
        shellDelegate?.shellTerminated(self, exitCode: code)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        // Parsed, washed, and only then shown. `feed(byteArray:)` would do the first and
        // the last in one call, and after a keystroke it draws at once — a frame of the
        // dark composer under every character typed into it. So the engine is fed
        // directly, and the view is handed an empty feed for the display it owes.
        getTerminal().feed(buffer: slice)
        backgroundWasher.sweep(getTerminal())
        feed(byteArray: [])
        noteColorSchemeRequests(in: slice)
        // One `gettimeofday` per burst on a path that already schedules a work item per
        // burst. It is what lets the status badge tell a thinking agent from a stopped one
        // — unless the burst is the pane echoing what was just typed into it.
        let now = Date()
        if !AgentEcho.isEcho(outputAt: now, afterInputAt: lastInputAt) { lastOutputAt = now }
        scheduleDirectoryProbe()
    }

    public func getWindowSize() -> winsize {
        let frame = getOptimalFrameSize()
        let terminal = getTerminal()
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
                       ws_xpixel: UInt16(frame.width), ws_ypixel: UInt16(frame.height))
    }
}
