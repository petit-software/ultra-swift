import AppKit
import SwiftUI
import UltraDesign

/// Branch, divergence, worktrees, and what has changed.
///
/// Every git verb here is behind an explicit click, and the only destructive one — discard —
/// asks first. Nothing in this tile runs on a timer that could rewrite the user's work.
public struct GitTile: View {
    @State private var model: GitModel
    @State private var confirming: GitModel.Change?
    private let context: TileContext

    /// `model` is the one the factory holds for this pane, so a menu command — New
    /// Worktree… — acts on the repository the pane is showing. A preview passes none.
    public init(context: TileContext, model: GitModel? = nil) {
        self.context = context
        _model = State(initialValue: model ?? GitModel(root: context.root))
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isRepository {
                // The diff opens in the EDITOR, not here.
                //
                // It used to replace this list, on the reasoning that a pane is as narrow as
                // the user made it and splitting it again would leave neither half readable.
                // That is true, and the conclusion was still wrong: it made the list and the
                // diff mutually exclusive, so reading a change meant losing sight of what
                // else had changed — and reviewing four files meant four round trips through
                // a back button. The editor already exists, it is where a file belongs, and
                // it holds tabs; four clicks here now fill it with four diffs.
                //
                // NO rule between the header and the list. A pane is one surface — see the
                // pane chrome, which gave up its own fill for the same reason — and a
                // hairline across it is a seam saying two things are stacked here when what
                // is actually stacked is a branch and the files on it. The gap between them
                // already separates them.
                header
                changeList
            } else {
                // Say WHICH directory was checked. "No repository here" on its own reads as
                // the tile being broken; naming the folder shows it is pointed somewhere the
                // user did not expect, which is the actual problem. The FOLDER, in the one
                // line, rather than the whole path on a second one — the footer's folder menu
                // carries the path, and it does so in every state of the tile.
                VStack(spacing: 10) {
                    EmptyTileState(icon: "arrow.trianglehead.branch",
                                   title: "No repository in \(context.root.lastPathComponent)")
                    // The fix for the state the user is looking at, offered where they are
                    // looking. The same verb as the footer's folder menu.
                    Button("Choose Folder…") {
                        guard let url = chooseTileFolder(title: "Repository Folder",
                                                         directory: context.root) else { return }
                        context.setRoot(url)
                    }
                    .buttonStyle(.plain)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.accentInk)
                }
            }
        }
        // A worktree verb git refused, in git's words: the one failure here that is not
        // already on screen as the state of a file.
        .tileToast(model.worktreeFailure.map(TileNotice.failed),
                   dismiss: { model.worktreeFailure = nil })
        .tileFooter { footer }
        .task { await poll() }
        .confirmationDialog("Discard changes to \(confirming?.path ?? "")?",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } })) {
            Button("Discard", role: .destructive) {
                if let change = confirming { Task { await model.discard(change) } }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("This cannot be undone from Ultra.")
        }
    }

    private var footer: some View {
        TileFooter(summary: summary) {
            // Which repository this tile is staging in, and how to point it at another one.
            // A Git tile follows the shell it was opened beside, and that shell may never
            // have been in the repository the user wants.
            TileFolderMenu(context: context, title: "Repository Folder")
            if model.isRepository {
                ChromeMenuButton(symbol: "square.stack.3d.up", help: "Worktrees",
                                 entries: worktreeEntries)
            }
            TileFooterButton(symbol: "arrow.clockwise", help: "Refresh now",
                             isEnabled: !model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
    }

    private var summary: String {
        model.isRepository
            ? "\(model.stagedCount) staged · \(model.unstagedCount) changed"
            : "no repository"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The NAME, with no glyph in front of it. The pane's own header already wears
                // the branch symbol and says "Git", so this was the second time the same
                // picture answered the same question — and it sat where the eye goes first,
                // pushing the one thing worth reading a symbol's width to the right.
                Text(model.branch ?? "detached HEAD")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Token.Colour.label)
                    .lineLimit(1)

                if model.ahead > 0 {
                    Label("\(model.ahead)", systemImage: "arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                if model.behind > 0 {
                    Label("\(model.behind)", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                if !model.changes.isEmpty {
                    Button("Stage All") { Task { await model.stageAll() } }
                        .buttonStyle(.plain)
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.accentInk)
                }
            }
            .font(Token.Type_.monoSmall)
            .foregroundStyle(Token.Colour.tertiaryLabel)

            // An in-flight rebase or merge is the single most important thing to say, so it
            // is stated outright rather than left for the user to infer from odd file states.
            if let operation = model.operation {
                Label(operation, systemImage: "exclamationmark.triangle.fill")
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(.orange)
            }

            // The branch's pull request, one click from the review it names. A PR is read
            // and discussed in a browser — this tile's job is only to say there is one and
            // to get you there without a trip through GitHub's branch list.
            if let pullRequest = model.pullRequest {
                PullRequestRow(pullRequest: pullRequest)
            }

            if model.worktrees.count > 1 { worktreeChips }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// The repository's worktrees, the one this pane is showing marked.
    ///
    /// A chip POINTS THE PANE at its worktree. It used to type a `cd` at the shell, which
    /// left the pane on the checkout it was already showing: the chip said "feature" and
    /// the list under it went on being main's. The `cd` is still here, on the right-click
    /// and in the footer's menu, with the rest of what can be done to a worktree.
    private var worktreeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.worktrees) { worktree in
                    Button { show(worktree) } label: {
                        Text(worktree.label)
                            .font(Token.Type_.monoSmall)
                            .strikethrough(worktree.isPrunable)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(worktree.isCurrent
                                        ? Token.Colour.accentWash
                                        : Token.Colour.label.opacity(0.06),
                                        in: .capsule)
                            .foregroundStyle(worktree.isCurrent
                                             ? Token.Colour.accentInk
                                             : Token.Colour.secondaryLabel)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(worktree.isPrunable)
                    .help(worktree.isPrunable
                          ? "\(TileFactory.abbreviate(worktree.path)) — its folder is gone"
                          : TileFactory.abbreviate(worktree.path))
                    .accessibilityLabel("Worktree \(worktree.label)")
                    .accessibilityHint("Shows this worktree in the pane")
                    .accessibilityAddTraits(worktree.isCurrent ? .isSelected : [])
                    .contextMenu {
                        Button("Show in This Pane") { show(worktree) }
                            .disabled(worktree.isCurrent || worktree.isPrunable)
                        Button("Go to Worktree in Shell") { sendToShell(worktree) }
                            .disabled(worktree.isPrunable)
                        Button("Show in Finder") {
                            context.revealInFinder(URL(fileURLWithPath: worktree.path))
                        }
                        .disabled(worktree.isPrunable)
                        Divider()
                        Button("Remove Worktree…") { remove(worktree) }
                            .disabled(worktree.isMain)
                    }
                }
            }
        }
        // Horizontal, and already hiding its indicator. The tile scroll bar reports
        // VERTICAL position; on a row of worktree chips it would be a marker for an
        // axis that does not move.
    }

    /// The footer's worktree menu: the list, then what can be done. The same verbs as
    /// Pane ▸ Git, and there with a single worktree too — which is when New is wanted.
    private func worktreeEntries() -> [ChromeMenuEntry] {
        var entries: [ChromeMenuEntry] = [.caption("Worktrees")]
        entries += model.worktrees.map { worktree in
            .item(title: worktree.label + (worktree.isPrunable ? " — folder gone" : ""),
                  isOn: worktree.isCurrent, isEnabled: !worktree.isPrunable) { show(worktree) }
        }
        let current = model.currentWorktree
        entries += [
            .separator,
            .item(title: "New Worktree…", symbol: "plus") {
                model.newWorktreeAfterAsking(show: context.setRoot)
            },
            .item(title: "Remove Worktree…", symbol: "minus.circle",
                  isEnabled: current.map { !$0.isMain } ?? false) {
                if let current { remove(current) }
            },
            .item(title: "Go to Worktree in Shell", symbol: "apple.terminal",
                  isEnabled: current != nil) {
                if let current { sendToShell(current) }
            },
        ]
        return entries
    }

    private func show(_ worktree: GitModel.Worktree) {
        guard !worktree.isCurrent else { return }
        context.setRoot(URL(fileURLWithPath: worktree.path))
    }

    private func sendToShell(_ worktree: GitModel.Worktree) {
        context.injectIntoShell("cd " + shellQuoted(worktree.path))
    }

    private func remove(_ worktree: GitModel.Worktree) {
        model.removeWorktreeAfterConfirming(worktree, show: context.setRoot)
    }

    @ViewBuilder
    private var changeList: some View {
        if model.changes.isEmpty {
            EmptyTileState(icon: "checkmark.circle", title: "Clean")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.changes) { change in
                        ChangeRow(change: change,
                                  open: { open(change) },
                                  stage: { Task { await model.stage(change) } },
                                  unstage: { Task { await model.unstage(change) } },
                                  discard: { confirming = change },
                                  send: { context.injectIntoShell(shellQuoted(change.path)) })
                    }
                }
                .padding(.vertical, 4)
            }
            .tileScrollBar()
        }
    }

    /// Show this file's diff in an editor pane.
    ///
    /// The available sides are worked out HERE, where the status is already in hand, so the
    /// editor never has to ask git a question this tile has already answered — and never
    /// offers a "Staged" tab for a file that has nothing staged.
    private func open(_ change: GitModel.Change) {
        context.openInEditor(.diff(DiffRequest(repositoryRoot: context.root,
                                               change: change,
                                               sides: model.availableSides(for: change))))
    }

    /// Polled, not watched. FSEvents would fire hundreds of times during a rebase or a
    /// build, and a status call per event is worse than a steady beat.
    private func poll() async {
        while !Task.isCancelled {
            await model.refresh()
            // On the same beat, but rate-limited inside the model to something a network
            // call can live with — usually this returns without asking GitHub anything.
            await model.refreshPullRequest()
            await TilePolling.tick(Preferences.gitInterval)
        }
    }
}

// MARK: Worktree verbs that ask first

@MainActor
public extension GitModel {

    /// Ask for a branch, add a worktree for it, and hand its folder to `show` — which
    /// points the pane there. Shared by the footer's menu and Pane ▸ Git ▸ New Worktree…,
    /// so both ask the same question.
    func newWorktreeAfterAsking(show: @escaping (URL) -> Void) {
        guard isRepository else { return }
        let main = worktrees.first(where: \.isMain)?.name ?? root.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "A branch to check out, or a name for a new one from HEAD. "
            + "It is added beside the repository, as \(main)-branch."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "branch"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add Worktree")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let branch = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        Task {
            if let url = await addWorktree(branch: branch) { show(url) }
        }
    }

    /// Remove a worktree once the user has said so. A pane that was showing it is handed
    /// the repository's own worktree, since its folder is gone.
    func removeWorktreeAfterConfirming(_ worktree: Worktree,
                                       show: @escaping (URL) -> Void) {
        guard !worktree.isMain else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree \(worktree.label)?"
        alert.informativeText = TileFactory.abbreviate(worktree.path)
            + " is deleted. Its branch and commits stay. A worktree with uncommitted changes"
            + " is not removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Worktree").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let main = worktrees.first(where: \.isMain)
        Task {
            guard await removeWorktree(worktree), worktree.isCurrent, let main else { return }
            show(URL(fileURLWithPath: main.path))
        }
    }
}

/// The pull request open on this branch, as a row you can click.
///
/// A whole row rather than a chip beside the branch: a PR is a title, and a title truncated
/// to fit next to a branch name is a link you have to open to find out what it is.
private struct PullRequestRow: View {
    let pullRequest: GitModel.PullRequest
    @State private var isHovering = false

    /// GitHub's own colours for its own states, because that is what the user has just been
    /// looking at in the browser. Draft is deliberately grey even though it is open: a draft
    /// is not asking to be reviewed.
    private var stateColour: Color {
        if pullRequest.isDraft { return Token.Colour.tertiaryLabel }
        switch pullRequest.state {
        case "OPEN": return .green
        case "MERGED": return .purple
        default: return .red
        }
    }

    /// Said in words only when it is NOT the ordinary case. An "OPEN" badge on every row is
    /// a word that never varies, which is a word nobody reads.
    private var stateLabel: String? {
        if pullRequest.isDraft { return "draft" }
        switch pullRequest.state {
        case "OPEN": return nil
        case "MERGED": return "merged"
        default: return "closed"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.pull")
                    .foregroundStyle(stateColour)
                Text("#\(pullRequest.number)")
                    .foregroundStyle(Token.Colour.label)
                Text(pullRequest.title)
                    .foregroundStyle(Token.Colour.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let stateLabel {
                    Text(stateLabel)
                        .foregroundStyle(stateColour)
                }
                Spacer(minLength: 0)
                // Says where the click goes BEFORE it is clicked — the one thing in this
                // tile that leaves the app.
                Image(systemName: "arrow.up.forward.square")
                    .opacity(isHovering ? 1 : 0)
            }
            .font(Token.Type_.monoSmall)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Token.Colour.label.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovering = $0 }
        .help("Open #\(pullRequest.number) in your browser")
        .accessibilityLabel("Pull request \(pullRequest.number), \(pullRequest.title)")
        .accessibilityHint("Opens on GitHub in your browser")
    }

    private func open() {
        guard let url = URL(string: pullRequest.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ChangeRow: View {
    let change: GitModel.Change
    let open: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let send: () -> Void
    @State private var isHovering = false

    /// Letter plus colour, never colour alone.
    private var mark: (String, Color) {
        switch (change.staged, change.unstaged) {
        case (_, .conflicted), (.conflicted, _): ("!", .orange)
        case (.untracked, _): ("?", Token.Colour.tertiaryLabel)
        case (.added, _): ("A", .green)
        case (.deleted, _), (_, .deleted): ("D", .red)
        case (.renamed, _): ("R", Token.Colour.accentInk)
        // Grey, not the accent: an edited file is the ORDINARY row in this list, and a
        // colour that sits on most rows stops marking anything.
        default: ("M", Token.Colour.secondaryLabel)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(mark.0)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(mark.1)
                .frame(width: 12)

            Text(change.path)
                .font(Token.Type_.mono)
                .foregroundStyle(change.isStaged ? Token.Colour.label : Token.Colour.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)

            if change.isStaged {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Token.Colour.accentInk)
                    .help("Staged")
            }

        }
        // Floating over the row's trailing end — see `tileHoverControls`. The cluster was a
        // column of this row, always laid out and only faded, so that nothing moved on
        // hover; that cost every path three glyphs' width of its head at rest. Same three
        // widths whether staged or not, so the pill is the same size on every row.
        .tileHoverControls(isHovering) {
            HStack(spacing: 8) {
                Button(action: send) { Image(systemName: "arrow.right.to.line") }
                    .help("Send path to shell")
                if change.isStaged {
                    Button(action: unstage) { Image(systemName: "minus.circle") }
                        .help("Unstage")
                } else {
                    Button(action: stage) { Image(systemName: "plus.circle") }
                        .help("Stage")
                }
                Button(action: discard) { Image(systemName: "arrow.uturn.backward") }
                    .help("Discard changes")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // The row opens the diff; the buttons on it keep their own actions because a
        // `.plain` button inside a tapped row still wins the hit.
        .onTapGesture(perform: open)
        .help("Show diff")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this file's diff")
    }
}

#Preview("Git", traits: .fixedLayout(width: 340, height: 380)) {
    GitTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
