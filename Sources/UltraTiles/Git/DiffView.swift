import SwiftUI
import UltraDesign

/// One file's diff, rendered in an editor session.
///
/// In the app rather than shelled out to a pager, because word-level highlighting inside a
/// changed line is most of the value and a pager gives none of it.
///
/// It lives in the EDITOR now rather than replacing the Git tile's list. A pane is already
/// as narrow as the user made it, and the old arrangement made the two mutually exclusive:
/// looking at a diff meant losing the list of what else had changed. Side by side, the list
/// stays a list and the diff gets the room it needs.
struct DiffView: View {
    @Bindable var session: DiffSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        // Keyed on the side so switching it reloads, and `loadIfNeeded` covers the rest:
        // a diff returned to after staging is marked stale and refetched, while one merely
        // redrawn is not.
        .task(id: session.side) { await session.loadIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The path, not just the name — the sidebar already carries the name, and
            // which of three `index.ts` this is remains the useful question.
            Text(session.path)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(Token.Colour.secondaryLabel)

            if let diff = session.diff, !diff.isEmpty, !diff.isBinary {
                Text("+\(diff.additions)")
                    .foregroundStyle(.green)
                Text("−\(diff.deletions)")
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 4)

            // Only offered when a file genuinely has both: a file can be staged AND
            // modified, and one button cannot mean two things.
            if session.sides.count > 1 {
                Picker("", selection: $session.side) {
                    ForEach(session.sides) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let diff = session.diff {
            if diff.isBinary {
                EmptyTileState(icon: "doc.badge.gearshape", title: "Binary file")
            } else if diff.isEmpty {
                EmptyTileState(icon: "equal.circle", title: "No changes on this side")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            HunkHeader(hunk: hunk)
                            ForEach(hunk.lines) { DiffLineRow(line: $0) }
                        }
                    }
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                }
            }
        } else {
            // Nothing loaded YET rather than nothing to load: the first fetch is the only
            // time this shows, because a reload keeps the previous diff on screen while it
            // runs rather than flashing the pane empty.
            EmptyTileState(icon: "clock", title: "Loading…")
        }
    }
}

private struct HunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        HStack(spacing: 6) {
            Text("@@ \(hunk.oldStart) → \(hunk.newStart)")
            if !hunk.heading.isEmpty {
                Text(hunk.heading).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Token.Colour.label.opacity(0.05))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    /// Sign plus tint, never tint alone — the same rule the change marks follow.
    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context, .marker: " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .addition: .green
        case .deletion: .red
        case .context: Token.Colour.secondaryLabel
        case .marker: Token.Colour.tertiaryLabel
        }
    }

    private var wash: Color {
        switch line.kind {
        case .addition: .green.opacity(0.10)
        case .deletion: .red.opacity(0.10)
        case .context, .marker: .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .foregroundStyle(tint)
                .frame(width: 14)
            emphasised
                .foregroundStyle(line.kind == .marker ? Token.Colour.tertiaryLabel
                                                      : Token.Colour.label)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 6)
        .background(wash)
    }

    /// The changed span carries a stronger wash than the rest of the line. A one-character
    /// change in a long line is invisible when the whole line is tinted evenly.
    private var emphasised: Text {
        guard let range = line.emphasis.first, !range.isEmpty else { return Text(line.text) }
        let characters = Array(line.text)
        guard range.lowerBound >= 0, range.upperBound <= characters.count else {
            return Text(line.text)
        }
        let before = String(characters[0..<range.lowerBound])
        let middle = String(characters[range])
        let after = String(characters[range.upperBound...])
        return Text(before)
            + Text(middle).bold().foregroundColor(tint)
            + Text(after)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Token.Colour.tertiaryLabel)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }
}
