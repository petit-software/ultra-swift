import AppKit
import SwiftUI
import UltraDesign

// No `tileHeaderInset()` here any more, deliberately. A tile does not hold itself off the
// pane header: `PaneContainerView` lays its content out BELOW the header, so a tile is
// handed a rectangle already clear of it, and re-applying the inset would leave every tile a
// second 36pt of nothing at the top. The footer's own band is `View.tileFooter`.

/// Ask the user where a tile's file should live.
///
/// A save panel rather than an open panel: the point is usually to CREATE the list
/// somewhere — `docs/TODO.md` in a repo that does not have one yet — and an open panel
/// cannot name a file that does not exist.
@MainActor
public func chooseTileFile(title: String,
                           suggestedName: String,
                           directory: URL,
                           allowedExtensions: [String]) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.nameFieldStringValue = suggestedName
    panel.directoryURL = directory
    panel.allowedContentTypes = []
    panel.allowsOtherFileTypes = true
    // Existing files are the normal case here — the panel is picking a location, not
    // guaranteeing a new document — so the overwrite warning would be wrong.
    panel.isExtensionHidden = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
}

/// Ask the user which folder a tile should be pointed at.
///
/// An open panel restricted to directories — the counterpart to `chooseTileFile`, which
/// picks where a file goes. "Choose" rather than "Open" as the button, because nothing is
/// opened: a pane is aimed somewhere else.
@MainActor
public func chooseTileFolder(title: String, directory: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = "Choose"
    panel.message = title
    panel.directoryURL = directory
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    // Dotfile-heavy work is the norm here: a `.git` or a `.build` has to be selectable, and
    // a panel that hides them makes a project's most interesting folders unreachable.
    panel.showsHiddenFiles = true
    return panel.runModal() == .OK ? panel.url : nil
}

/// Ask the user which files or folders to add to a tile's list.
///
/// Files AND directories, and several at a time: this is the panel behind the Context tile's
/// `+`, and gathering context is a bulk verb — dropping six files from Finder in one gesture
/// already works, so the keyboard-reachable path must not be six trips through a panel.
///
/// "Add" rather than "Open", because nothing is opened: the tile takes a reference.
@MainActor
public func chooseTileItems(title: String, directory: URL) -> [URL] {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = "Add"
    panel.message = title
    panel.directoryURL = directory
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    // The same reason `chooseTileFolder` shows them: a `.github` or a `.ultra` is exactly
    // the kind of folder someone hands an agent.
    panel.showsHiddenFiles = true
    return panel.runModal() == .OK ? panel.urls : []
}

// MARK: - Nothing to show

/// A tile with nothing in it yet: one symbol, one line.
///
/// ONE line, and it is the title. Every empty state used to carry a quieter second line under
/// it — where the files come from, which folder was checked, what to click — and in a pane the
/// width of a sidebar those lines wrapped to three, which made the emptiest state in the app
/// the wordiest thing in it.
///
/// Nothing is actually lost. The footer names the folder a tile is pointed at in EVERY state
/// rather than only this one, so a path repeated here was the same fact twice; and where there
/// is something to be done about the emptiness, the control that does it sits under the line
/// instead of a sentence describing it. `TodoTile` got there first — the note where its path
/// used to be says so — and now shares this view rather than keeping a copy of it.
struct EmptyTileState: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text(title)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.secondaryLabel)
                // A pane can be dragged down to 160pt, where even a short phrase runs to two
                // lines. Centred, because the symbol above it is.
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
