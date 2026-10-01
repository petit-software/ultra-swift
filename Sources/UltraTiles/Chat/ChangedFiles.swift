import AppKit
import SwiftUI
import UltraChat
import UltraDesign

/// The files an answer changed: one row per file, whatever the number of calls that
/// touched it, with what became of it and the size of the change beside the name.
///
/// Shown as a table rather than as the tool rows the changes came in as, because what the
/// user wants to know is WHICH files and HOW MUCH, not the model's sequence of calls —
/// and a table of one is the same table, so a single change does not look like a
/// different thing from two. A file added or deleted is a row of the same table as one
/// edited: a change is a change, whichever way it came.
struct ChangedFile: Identifiable, Equatable {
    let path: String
    var additions: Int
    var deletions: Int
    var kind: ChatFileChange.Kind
    /// Whether every call that touched the file has answered. Counts are shown only then:
    /// a Codex edit is named before it is counted, and `+0 −0` would read as nothing.
    var isSettled: Bool

    var id: String { path }

    /// The rows for a set of calls: each file once, in the order first touched, with every
    /// change to it added up. A call with no changes contributes nothing — a read, a
    /// command that touched no file, or an edit that failed, which stays the plain row it
    /// always was.
    static func rows(in calls: [ChatToolCall]) -> [ChangedFile] {
        var rows: [ChangedFile] = []
        for call in calls {
            for change in call.changes ?? [] {
                if let index = rows.firstIndex(where: { $0.path == change.path }) {
                    rows[index].additions += change.additions
                    rows[index].deletions += change.deletions
                    rows[index].kind = rows[index].kind.followed(by: change.kind)
                    rows[index].isSettled = rows[index].isSettled && call.result != nil
                } else {
                    rows.append(ChangedFile(path: change.path, additions: change.additions,
                                            deletions: change.deletions, kind: change.kind,
                                            isSettled: call.result != nil))
                }
            }
        }
        return rows
    }

    /// The calls of the answer a message ends: its own and those of every assistant turn
    /// before it, back to the question — a turn that calls tools is followed by another,
    /// the model going on with the results, and the files all of them touched are one
    /// answer's. Nil for a message that is not an answer's last, so the table is drawn
    /// once, under the whole of it, rather than once per turn.
    static func answer(endingAt index: Int, in messages: [ChatMessage]) -> [ChatToolCall]? {
        guard messages.indices.contains(index), messages[index].role == .assistant else { return nil }
        let next = index + 1
        if messages.indices.contains(next), messages[next].role == .assistant { return nil }
        var start = index
        while start > 0, messages[start - 1].role == .assistant { start -= 1 }
        return messages[start...index].flatMap { $0.toolCalls ?? [] }
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

extension ChatFileChange.Kind {
    /// What a file is after one more change: deleted when the last word was `rm`; a file
    /// added and then edited is still new; one deleted and then written again is, for the
    /// answer as a whole, changed.
    func followed(by next: ChatFileChange.Kind) -> ChatFileChange.Kind {
        switch (self, next) {
        case (_, .deleted): .deleted
        case (.deleted, _): .modified
        case (.added, _): .added
        default: self
        }
    }
}

/// The changed files, stacked in one bordered, rounded table. Each row is the same height
/// and opens its file in the editor — but a deleted one, which has nowhere to open.
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
        if file.kind == .deleted {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
        } else {
            Button(action: open) {
                row.background(isHovering ? Token.Colour.label.opacity(0.06) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open \(file.name) in the editor")
            .accessibilityLabel(label)
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.secondaryLabel)
                .frame(width: 14)
            Text(file.name)
                .font(Token.Type_.body)
                .foregroundStyle(file.kind == .deleted ? Token.Colour.secondaryLabel : Token.Colour.label)
                .strikethrough(file.kind == .deleted, color: Token.Colour.secondaryLabel)
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
                counts
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
        .contentShape(Rectangle())
    }

    /// `+12 −3` for an edit; a new file is all additions and a deleted one all deletions,
    /// so each shows the one side that means anything.
    @ViewBuilder
    private var counts: some View {
        switch file.kind {
        case .added:
            Text("+\(file.additions)").foregroundStyle(.green)
        case .deleted:
            Text("−\(file.deletions)").foregroundStyle(.red)
        case .modified:
            HStack(spacing: 5) {
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
        }
    }

    private var symbol: String {
        switch file.kind {
        case .modified: "doc.text"
        case .added: "doc.badge.plus"
        case .deleted: "trash"
        }
    }

    private var label: String {
        guard file.isSettled else { return "\(file.name), being changed" }
        switch file.kind {
        case .added: return "\(file.name), new, \(file.additions) lines"
        case .deleted: return "\(file.name), deleted, \(file.deletions) lines"
        case .modified: return "\(file.name), \(file.additions) lines added, \(file.deletions) removed"
        }
    }
}

#Preview("Changed files", traits: .fixedLayout(width: 360, height: 220)) {
    let root = URL(fileURLWithPath: "/Users/me/Project")
    VStack(spacing: 12) {
        ChangedFilesTable(files: [
            ChangedFile(path: "/Users/me/Project/Sources/App/ContentView.swift", additions: 12, deletions: 3, kind: .modified, isSettled: true),
            ChangedFile(path: "/Users/me/Project/Sources/App/NewView.swift", additions: 40, deletions: 0, kind: .added, isSettled: true),
            ChangedFile(path: "/Users/me/Project/Sources/App/OldView.swift", additions: 0, deletions: 18, kind: .deleted, isSettled: true),
            ChangedFile(path: "/Users/me/Project/Tests/AppTests/A very long test file name indeed.swift", additions: 40, deletions: 0, kind: .modified, isSettled: false),
        ], root: root) { _ in }
        ChangedFilesTable(files: [
            ChangedFile(path: "/Users/me/Project/README.md", additions: 2, deletions: 0, kind: .modified, isSettled: true),
        ], root: root) { _ in }
    }
    .padding(12)
}
