import AppKit
import SwiftUI
import UltraCore
import UltraDesign

/// The project's files, as a lazily-expanded tree.
///
/// Clicking a file opens it in the editor; double-clicking it reveals it in Finder. Sending
/// its shell-quoted path to the focused shell — the verb Todo and Context rows share — is
/// on the hover pill and the context menu, one click away rather than the click.
public struct FileTreeTile: View {
    @State private var model: FileTreeModel
    @State private var selection: URL?
    private let context: TileContext

    public init(context: TileContext) {
        self.context = context
        _model = State(initialValue: FileTreeModel(root: context.root))
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // `..` first, the way every file list since the 1980s has opened. Going up
                // is the one move a lazily-expanded tree cannot make on its own — everything
                // below the root is one click away, and everything above it was unreachable.
                if let parent {
                    ParentRow(name: parent.lastPathComponent)
                        .contentShape(.rect)
                        .onTapGesture { context.setRoot(parent) }
                }
                ForEach(model.rows) { row in
                    FileTreeRow(row: row,
                                isSelected: selection == row.node.url,
                                isExpanded: model.isExpanded(row.node),
                                isUnreadable: model.unreadable.contains(row.node.url),
                                open: { open(row.node) },
                                send: { send(row.node) },
                                reveal: { context.revealInFinder(row.node.url) })
                        .contentShape(.rect)
                        .onTapGesture { activate(row.node) }
                        .contextMenu { menu(for: row.node) }
                }
            }
            .padding(.vertical, 4)
        }
        // On the pane where no row is: what the footer does, by name.
        .contextMenu { paneMenu }
        .tileScrollBar()
        .tileFooter { footer }
    }

    /// The folder above this one, or nil at the root of the volume.
    private var parent: URL? {
        let up = context.root.deletingLastPathComponent().standardizedFileURL
        return up.path == context.root.standardizedFileURL.path ? nil : up
    }

    private var footer: some View {
        TileFooter(summary: "\(model.rows.count) shown") {
            // Where this tree is rooted. The `..` row walks up one level at a time; this
            // reaches anywhere, including back to the project.
            TileFolderMenu(context: context, title: "Folder to Show")
            // The same verb, glyph and key as the editor's own footer. Here because this is
            // where you are looking when you notice the file you want does not exist yet.
            TileFooterButton(symbol: "plus.circle", help: "New file (⌃⌘N)") {
                context.openInEditor(.newFile)
            }
            TileFooterButton(symbol: model.showsHidden ? "eye" : "eye.slash",
                             help: model.showsHidden ? "Hide dotfiles" : "Show dotfiles") {
                model.showsHidden.toggle()
            }
            TileFooterButton(symbol: "arrow.clockwise", help: "Reload") { model.reload() }
            TileFooterButton(symbol: "square.fill.on.square.fill", help: "Open this folder in Finder") {
                context.revealInFinder(model.root)
            }
        }
    }

    /// A row's menu: everything the row's click, double click and hover buttons do, by
    /// name, and the things a file tree is expected to do that had no control at all —
    /// copy a path, rename, move to the Trash.
    @ViewBuilder
    private func menu(for node: FileTreeModel.Node) -> some View {
        if node.isDirectory {
            Button(model.isExpanded(node) ? "Collapse" : "Expand") { model.toggle(node) }
            // Descending INTO a folder, as opposed to expanding it in place: a deep tree in
            // a 300pt pane is mostly indentation, and re-rooting buys the width back.
            Button("Show Only This Folder") { open(node) }
            Button("Go to Folder in Shell") {
                context.injectIntoShell("cd " + shellQuoted(node.url.path))
            }
        } else {
            Button("Open in Editor") { open(node) }
            Button("Open in Default App") { NSWorkspace.shared.open(node.url) }
        }
        Divider()
        Button("Send Path to Shell") { send(node) }
        Button("Copy Path") { copyToClipboard(node.url.path) }
        Button("Copy Relative Path") { copyToClipboard(relativePath(node.url)) }
        Button("Copy Name") { copyToClipboard(node.name) }
        Divider()
        Button("Reveal in Finder") { context.revealInFinder(node.url) }
        Divider()
        Button("Rename…") { rename(node) }
        Button("Move to Trash", role: .destructive) { trash(node) }
    }

    @ViewBuilder
    private var paneMenu: some View {
        Button("New File") { context.openInEditor(.newFile) }
        Divider()
        Button(model.showsHidden ? "Hide Dotfiles" : "Show Dotfiles") { model.showsHidden.toggle() }
        Button("Reload") { model.reload() }
        Divider()
        if let parent {
            Button("Show Enclosing Folder") { context.setRoot(parent) }
        }
        Button("Go to Folder in Shell") {
            context.injectIntoShell("cd " + shellQuoted(model.root.path))
        }
        Button("Copy Path") { copyToClipboard(model.root.path) }
        Button("Open Folder in Finder") { context.revealInFinder(model.root) }
    }

    /// The path from the project, where the file is under it: what an agent or an import
    /// wants. The whole path otherwise.
    private func relativePath(_ url: URL) -> String {
        let root = context.projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Ask for a new name, and give the file it. A name that is taken, or cannot be
    /// given, says why rather than doing nothing.
    private func rename(_ node: FileTreeModel.Node) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(node.name)”"
        let field = NSTextField(string: node.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.name, !name.contains("/") else { return }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: destination)
            if selection == node.url { selection = destination }
            model.reload()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// To the Trash, not deleted: it can be put back from there, which is why this does
    /// not ask first — Finder does not either.
    private func trash(_ node: FileTreeModel.Node) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if selection == node.url { selection = nil }
            model.reload()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// One handler for both clicks of a double, so the first is never held back waiting to
    /// see whether a second follows: the editor opens at once, and the second click of a
    /// double reveals the file in Finder on top of that. A folder expands in place on each
    /// click, as before.
    private func activate(_ node: FileTreeModel.Node) {
        selection = node.url
        if node.isDirectory {
            model.toggle(node)
        } else if NSApp.currentEvent?.clickCount == 2 {
            context.revealInFinder(node.url)
        } else {
            open(node)
        }
    }

    /// What "open" means for each kind: a file goes to the editor, and a folder becomes the
    /// tree's root — the one way of opening a folder that a click, which expands it in
    /// place, does not already do.
    private func open(_ node: FileTreeModel.Node) {
        if node.isDirectory {
            context.setRoot(node.url)
        } else {
            context.openInEditor(.file(node.url))
        }
    }

    /// Quoted, because a path with a space that arrives at the prompt unquoted is two
    /// arguments and a confusing error.
    private func send(_ node: FileTreeModel.Node) {
        context.injectIntoShell(shellQuoted(node.url.path))
    }
}

/// The `..` row. Deliberately not a `FileTreeRow`: it is a move, not a file, and it wears
/// the icon of the folder it takes you to rather than a document.
private struct ParentRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            // The size of the icons in the pane's header and footer: it is a control, and
            // reads as one of them.
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: ChromeIconLabel.size - 2, weight: .semibold))
                .frame(width: 16)
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .frame(width: 14)
            Text("..")
                .font(Token.Type_.tileSubtitle)
            Text(name)
                .font(Token.Type_.monoSmall)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .help("Show the enclosing folder")
        .accessibilityLabel("Enclosing folder, \(name)")
        .accessibilityAddTraits(.isButton)
    }
}

private struct FileTreeRow: View {
    let row: FileTreeModel.Row
    let isSelected: Bool
    let isExpanded: Bool
    let isUnreadable: Bool
    let open: () -> Void
    let send: () -> Void
    let reveal: () -> Void
    @State private var isHovering = false

    private var icon: String {
        // Filled, folder and file alike: the outline glyphs were thin at this size, and
        // the chevron says whether a folder is open.
        if row.node.isDirectory { return "folder.fill" }
        return "text.page.fill"
    }

    var body: some View {
        HStack(spacing: 5) {
            // A fixed-width well, so names line up whether or not a row has a chevron.
            Group {
                if row.node.isDirectory {
                    // The size of the icons in the pane's header and footer, like the
                    // `..` row's arrow: the grey marks down the left are controls.
                    Image(systemName: "chevron.right")
                        .font(.system(size: ChromeIconLabel.size - 2, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
            .foregroundStyle(Token.Colour.tertiaryLabel)

            // Folder and file in the one grey: the chevron and the filled folder already
            // say which is which, and a second colour for folders made the tree a column
            // of marks competing with the names.
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Token.Colour.secondaryLabel)
                .frame(width: 14)

            Text(row.node.name)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(isUnreadable ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .lineLimit(1)
                .truncationMode(.middle)

            if isUnreadable {
                Image(systemName: "lock")
                    .font(.system(size: 9))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .help("Cannot be read")
            }
            Spacer(minLength: 0)
        }
        // Floating over the row's trailing end — see `tileHoverControls`. The same three
        // on a file and on a folder, so the pill is one size all the way down the tree;
        // only what Open means differs. Each is also on the row's context menu.
        .tileHoverControls(isHovering) {
            HStack(spacing: 7) {
                Button(action: open) {
                    Image(systemName: row.node.isDirectory ? "arrow.turn.down.right" : "doc.text")
                }
                .help(row.node.isDirectory ? "Show only this folder" : "Open in the editor")
                .disabled(isUnreadable)
                Button(action: send) { Image(systemName: "arrow.right.to.line") }
                    .help("Send path to shell")
                Button(action: reveal) { Image(systemName: "magnifyingglass") }
                    .help("Reveal in Finder")
            }
            .font(.system(size: 11))
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 13)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Token.Colour.accentWashStrong)
                    .padding(.horizontal, 4)
            }
        }
        .animation(Token.Motion.structuralRespectingPreferences, value: isExpanded)
    }
}

#Preview("File tree", traits: .fixedLayout(width: 320, height: 480)) {
    FileTreeTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
