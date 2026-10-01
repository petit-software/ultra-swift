import AppKit
import SwiftUI
import UltraChat
import UltraDesign

/// The files an answer changed: one row per file, whatever the number of edits that
/// touched it, with the size of the change beside the name.
///
/// Shown as a table rather than as the tool rows the edits came in as, because what the
/// user wants to know is WHICH files and HOW MUCH, not the model's sequence of calls —
/// and a table of one is the same table, so a single change does not look like a
/// different thing from two.
struct ChangedFile: Identifiable, Equatable {
    let path: String
    var additions: Int
    var deletions: Int
    /// Whether every edit that touched the file has answered. Counts are shown only then:
    /// a Codex edit is named before it is counted, and `+0 −0` would read as nothing.
    var isSettled: Bool

    var id: String { path }

    /// The rows for a turn's calls: each file once, in the order first touched, with every
    /// edit to it added up. A call with no changes contributes nothing — a read, a command,
    /// or an edit that failed, which stays the plain row it always was.
    static func rows(in calls: [ChatToolCall]) -> [ChangedFile] {
        var rows: [ChangedFile] = []
        for call in calls {
            for change in call.changes ?? [] {
                if let index = rows.firstIndex(where: { $0.path == change.path }) {
                    rows[index].additions += change.additions
                    rows[index].deletions += change.deletions
                    rows[index].isSettled = rows[index].isSettled && call.result != nil
                } else {
                    rows.append(ChangedFile(path: change.path, additions: change.additions,
                                            deletions: change.deletions, isSettled: call.result != nil))
                }
            }
        }
        return rows
    }

    /// The first call the table stands in for, so it takes the edits' place among the
    /// other rows rather than a place of its own.
    static func firstEdit(in calls: [ChatToolCall]) -> String? {
        calls.first { !($0.changes ?? []).isEmpty }?.id
    }

    var name: String { (path as NSString).lastPathComponent }

    /// The file on disk: an engine names files absolutely, but a relative one is taken as
    /// the project's.
    func url(under root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// Where the file is, from the project down — `Sources/UltraChat` — so three files of
    /// one name tell apart without the project's whole path on every row. Empty for a file
    /// at the root.
    func folder(under root: URL) -> String {
        let directory = (url(under: root).deletingLastPathComponent().path as NSString).standardizingPath
        let base = (root.path as NSString).standardizingPath
        if directory == base { return "" }
        if directory.hasPrefix(base + "/") { return String(directory.dropFirst(base.count + 1)) }
        return (directory as NSString).abbreviatingWithTildeInPath
    }
}

/// The changed files, stacked in one bordered, rounded table. Each row is the same height
/// and opens its file in the editor.
struct ChangedFilesTable: View {
    let files: [ChangedFile]
    let root: URL
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                if index > 0 {
                    Divider().overlay(Token.Colour.separator)
                }
                ChangedFileRow(file: file, root: root) { open(file.url(under: root)) }
            }
        }
        .background(Token.Colour.label.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Token.Colour.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }
}

private struct ChangedFileRow: View {
    static let height: CGFloat = 30

    let file: ChangedFile
    let root: URL
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.secondaryLabel)
                    .frame(width: 14)
                Text(file.name)
                    .font(Token.Type_.body)
                    .foregroundStyle(Token.Colour.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                let folder = file.folder(under: root)
                if !folder.isEmpty {
                    Text(folder)
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if file.isSettled {
                    HStack(spacing: 5) {
                        Text("+\(file.additions)").foregroundStyle(.green)
                        Text("−\(file.deletions)").foregroundStyle(.red)
                    }
                    .font(Token.Type_.monoSmall)
                    .monospacedDigit()
                } else {
                    Text("…")
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Token.Colour.label.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(file.name) in the editor")
        .accessibilityLabel(file.isSettled
                            ? "\(file.name), \(file.additions) lines added, \(file.deletions) removed"
                            : "\(file.name), being changed")
    }
}

#Preview("Changed files", traits: .fixedLayout(width: 360, height: 160)) {
    let root = URL(fileURLWithPath: "/Users/me/Project")
    VStack(spacing: 12) {
        ChangedFilesTable(files: [
            ChangedFile(path: "/Users/me/Project/Sources/App/ContentView.swift", additions: 12, deletions: 3, isSettled: true),
            ChangedFile(path: "/Users/me/Project/Package.swift", additions: 1, deletions: 1, isSettled: true),
            ChangedFile(path: "/Users/me/Project/Tests/AppTests/A very long test file name indeed.swift", additions: 40, deletions: 0, isSettled: false),
        ], root: root) { _ in }
        ChangedFilesTable(files: [
            ChangedFile(path: "/Users/me/Project/README.md", additions: 2, deletions: 0, isSettled: true),
        ], root: root) { _ in }
    }
    .padding(12)
}
