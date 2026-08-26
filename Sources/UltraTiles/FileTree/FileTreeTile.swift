import AppKit
import SwiftUI
import UltraCore
import UltraDesign

/// The project's files, as a lazily-expanded tree.
///
/// Clicking a file sends its path to the focused shell WITHOUT submitting — the same verb
/// Todo and Context use. A file tree that opened an editor would be a worse editor than the
/// one the user already has; a file tree that types a path for you is the thing a terminal
/// actually lacks.
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
                                isUnreadable: model.unreadable.contains(row.node.url))
                        .contentShape(.rect)
                        .onTapGesture { activate(row.node) }
                        .contextMenu { menu(for: row.node) }
                }
            }
            .padding(.vertical, 4)
        }
        .tileScrollBar()
        .tileFooter { footer }
        .tileHeaderInset()
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
            TileFooterButton(symbol: model.showsHidden ? "eye" : "eye.slash",
                             help: model.showsHidden ? "Hide dotfiles" : "Show dotfiles") {
                model.showsHidden.toggle()
            }
            TileFooterButton(symbol: "arrow.clockwise", help: "Reload") { model.reload() }
        }
    }

    @ViewBuilder
    private func menu(for node: FileTreeModel.Node) -> some View {
        if node.isDirectory {
            // Descending INTO a folder, as opposed to expanding it in place: a deep tree in
            // a 300pt pane is mostly indentation, and re-rooting buys the width back.
            Button("Show Only This Folder") { context.setRoot(node.url) }
        } else {
            Button("Open in Editor") { context.openInEditor(node.url) }
        }
        Button("Send Path to Shell") { send(node) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Button("Reveal in Finder") { context.revealInFinder(node.url) }
    }

    private func activate(_ node: FileTreeModel.Node) {
        selection = node.url
        if node.isDirectory {
            model.toggle(node)
        } else {
            send(node)
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
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 10)
            Image(systemName: "folder")
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
        .padding(.leading, 8)
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

    private var icon: String {
        if row.node.isDirectory { return isExpanded ? "folder.fill" : "folder" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 5) {
            // A fixed-width well, so names line up whether or not a row has a chevron.
            Group {
                if row.node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            .foregroundStyle(Token.Colour.tertiaryLabel)

            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(row.node.isDirectory
                                 ? Token.Colour.accent
                                 : Token.Colour.secondaryLabel)
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
        .padding(.leading, 8 + CGFloat(row.depth) * 13)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
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
