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
                header
                Divider().overlay(Token.Colour.divider)
                changeList
            } else {
                EmptyTileState(icon: "arrow.trianglehead.branch",
                               title: "Not a git repository",
                               detail: TileFactory.abbreviate(context.root.path))
            }
            TileFooter(isBusy: model.isRefreshing, summary: summary) { await model.refresh() }
        }
        .background(Token.Colour.paneBackground)
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

    private var summary: String {
        model.isRepository
            ? "\(model.stagedCount) staged · \(model.unstagedCount) changed"
            : "no repository"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Token.Colour.accent)
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

            if model.worktrees.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.worktrees) { worktree in
                            Text(worktree.branch ?? worktree.name)
                                .font(Token.Type_.monoSmall)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(worktree.isCurrent
                                            ? Token.Colour.accent.opacity(0.18)
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
                                  stage: { Task { await model.stage(change) } },
                                  unstage: { Task { await model.unstage(change) } },
                                  discard: { confirming = change },
                                  send: { context.injectIntoShell(shellQuoted(change.path)) })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Polled, not watched. FSEvents would fire hundreds of times during a rebase or a
    /// build, and a status call per event is worse than a steady beat.
    private func poll() async {
        while !Task.isCancelled {
            await model.refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

private struct ChangeRow: View {
    let change: GitModel.Change
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
    }
}

#Preview("Git", traits: .fixedLayout(width: 340, height: 380)) {
    GitTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
