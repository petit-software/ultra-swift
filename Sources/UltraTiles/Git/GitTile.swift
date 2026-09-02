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

    public init(context: TileContext) {
        self.context = context
        _model = State(initialValue: GitModel(root: context.root))
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
                    .foregroundStyle(Token.Colour.accent)
                }
            }
        }
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
                        .foregroundStyle(Token.Colour.accent)
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

            if model.worktrees.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.worktrees) { worktree in
                            Text(worktree.branch ?? worktree.name)
                                .font(Token.Type_.monoSmall)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(worktree.isCurrent
                                            ? Token.Colour.accentWash
                                            : Token.Colour.label.opacity(0.06),
                                            in: .capsule)
                                .foregroundStyle(worktree.isCurrent
                                                 ? Token.Colour.accent
                                                 : Token.Colour.secondaryLabel)
                                .onTapGesture {
                                    context.injectIntoShell("cd " + shellQuoted(worktree.path))
                                }
                        }
                    }
                }
                // Horizontal, and already hiding its indicator. The tile scroll bar reports
                // VERTICAL position; on a row of worktree chips it would be a marker for an
                // axis that does not move.
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        case (.renamed, _): ("R", Token.Colour.accent)
        default: ("M", Token.Colour.accent)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(mark.0)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(mark.1)
                .frame(width: 12)

            Text(change.path)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(change.isStaged ? Token.Colour.label : Token.Colour.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)

            if isHovering {
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
            } else if change.isStaged {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Token.Colour.accent)
                    .help("Staged")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
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
