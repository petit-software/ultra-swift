import SwiftUI
import UltraDesign

/// The strip along the bottom of a tile: icon controls on the left, one line of status on
/// the right.
///
/// Shared because six tiles had each grown their own — the same `HStack` with the same
/// `.thinMaterial`, but with its own padding, its own icon sizing, and its own idea of
/// which way round controls and status went. Editor put its status on the LEFT and its
/// buttons on the right; every other tile did the opposite. Stacked in one window they read
/// as six different apps.
///
/// Controls lead, status trails. That order is the rule: the things you can press are always
/// in the same corner, whichever tile you are looking at.
public struct TileFooter<Controls: View>: View {
    let summary: String
    /// Paths truncate from the head — the tail is the part that identifies the file. Counts
    /// and totals truncate from the tail, but they are short enough that it never shows.
    var truncation: Text.TruncationMode = .tail
    var summaryHelp: String?
    @ViewBuilder let controls: () -> Controls

    public init(summary: String,
                truncation: Text.TruncationMode = .tail,
                summaryHelp: String? = nil,
                @ViewBuilder controls: @escaping () -> Controls) {
        self.summary = summary
        self.truncation = truncation
        self.summaryHelp = summaryHelp
        self.controls = controls
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Spacing 1, the same as a pane header's control cluster: each icon brings its
            // own 28pt box, so anything wider double-counts the gap.
            HStack(spacing: 1) { controls() }
            Spacer(minLength: 8)
            if !summary.isEmpty {
                Text(summary)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(truncation)
                    .help(summaryHelp ?? "")
            }
        }
        .buttonStyle(.plain)
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.leading, 5)
        .padding(.trailing, 10)
        // The same height as a pane header, so the two ends of a tile are the same weight
        // and a column of tiles has one horizontal rhythm rather than several.
        .frame(height: Token.Space.tileHeaderHeight)
        // No background. The footer occupies its own band of the tile — see `tileFooter` —
        // so what sits behind it is the pane's own surface and nothing else. A material or
        // a fill here would be a second surface inside the pane; a see-through blur, which
        // is what was here, let the list scroll up through the status line.
    }
}

/// One icon control in a tile footer.
///
/// The chrome — size, hit area, hover plate, disabled dimming — is `ChromeIconButton`, the
/// same control a pane header wears. A footer icon and a header icon are the same object at
/// opposite ends of the same tile, and they used to be two different sizes in two different
/// boxes.
public struct TileFooterButton: View {
    let symbol: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    public init(symbol: String, help: String, isEnabled: Bool = true,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        ChromeIconButton(symbol: symbol, help: help, isEnabled: isEnabled, action: action)
    }
}

/// The "where is this list stored" control, shared by every tile that keeps a file.
///
/// Context and Todo had the same folder menu written out twice, down to the modifier stack.
/// One of them was always going to drift.
public struct TileStoreMenu: View {
    let path: String
    let help: String
    let choose: () -> Void
    let reset: () -> Void

    public init(path: String, help: String,
                choose: @escaping () -> Void, reset: @escaping () -> Void) {
        self.path = path
        self.help = help
        self.choose = choose
        self.reset = reset
    }

    public var body: some View {
        ChromeMenuButton(symbol: "folder", help: help) {
            [.caption(TileFactory.abbreviate(path)),
             .separator,
             .item(title: "Choose Location…", action: choose),
             .item(title: "Use Project Default", action: reset)]
        }
    }
}

/// The "which folder is this tile looking at" control, shared by every folder-scoped tile.
///
/// A tile is created pointing at the shell's folder, and that is right until it isn't: a
/// repository is a sibling of the project, a file tree wants the directory ABOVE the one it
/// opened in, a second Git tile watches a worktree. Before this, the only way to move a tile
/// was to close it, `cd` in a shell, and open a new one.
///
/// The four destinations are the ones that actually come up — an arbitrary folder, one level
/// up, wherever the shell is now, and back to the project. Each is greyed rather than hidden
/// when it would not move the tile, so the menu's shape is the same every time it opens.
public struct TileFolderMenu: View {
    let context: TileContext
    /// What the chooser panel is asking for, in this tile's words.
    let title: String

    public init(context: TileContext, title: String) {
        self.context = context
        self.title = title
    }

    private var parent: URL? {
        let up = context.root.deletingLastPathComponent().standardizedFileURL
        return up.path == context.root.standardizedFileURL.path ? nil : up
    }

    public var body: some View {
        let help = "Folder — " + TileFactory.abbreviate(context.root.path)
        return ChromeMenuButton(symbol: "folder", help: help) {
            let here = context.root.standardizedFileURL.path
            let shell = context.currentDirectory().standardizedFileURL
            let project = context.projectRoot.standardizedFileURL
            return [
                .caption(TileFactory.abbreviate(context.root.path)),
                .separator,
                .item(title: "Choose Folder…", symbol: "folder.badge.gearshape", action: choose),
                .item(title: "Go Up", symbol: "arrow.up",
                      isEnabled: parent != nil) { if let parent { context.setRoot(parent) } },
                .item(title: "Follow Shell", symbol: "apple.terminal",
                      isEnabled: shell.path != here) { context.setRoot(shell) },
                .item(title: "Project Folder", symbol: "house",
                      isEnabled: project.path != here) { context.setRoot(project) },
            ]
        }
    }

    private func choose() {
        guard let url = chooseTileFolder(title: title, directory: context.root) else { return }
        context.setRoot(url)
    }
}

public extension View {
    /// Gives a tile's footer a band of its own at the foot of the tile.
    ///
    /// A STACK, which is the same thing `PaneContainerView` does for the header at the other
    /// end: the content is handed a rectangle that stops where the chrome starts, so there
    /// is nothing to see through and no material to hide anything with.
    ///
    /// Both of the obvious spellings are wrong here, and both were tried. An overlay with
    /// content margins keeps the scroll view full height and lets rows slide under the bar.
    /// `safeAreaInset` looks like the fix and is not: it shrinks the safe AREA, while the
    /// scroll view keeps its frame and goes on drawing through the inset — which is exactly
    /// the see-through footer this is meant to end. Only a real frame stops a scroll view.
    func tileFooter<Footer: View>(@ViewBuilder _ footer: () -> Footer) -> some View {
        VStack(spacing: 0) {
            frame(maxWidth: .infinity, maxHeight: .infinity)
            footer()
        }
    }
}

#Preview("Tile footer", traits: .fixedLayout(width: 340, height: 44)) {
    TileFooter(summary: "12 shown") {
        TileFooterButton(symbol: "eye.slash", help: "Show dotfiles") {}
        TileFooterButton(symbol: "arrow.clockwise", help: "Reload") {}
        TileFooterButton(symbol: "trash", help: "Delete", isEnabled: false) {}
    }
}
