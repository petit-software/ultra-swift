import SwiftUI
import UltraDesign

/// One file's diff, rendered in the pane.
///
/// In the pane rather than shelled out to a pager, because word-level highlighting inside a
/// changed line is most of the value and a pager gives none of it.
struct DiffView: View {
    let change: GitModel.Change
    let sides: [DiffSide]
    let load: (DiffSide) async -> FileDiff
    let close: () -> Void

    @State private var side: DiffSide
    @State private var diff: FileDiff?
    @State private var isLoading = true

    init(change: GitModel.Change, sides: [DiffSide],
         load: @escaping (DiffSide) async -> FileDiff, close: @escaping () -> Void) {
        self.change = change
        self.sides = sides
        self.load = load
        self.close = close
        _side = State(initialValue: sides.first ?? .unstaged)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        .task(id: side) { await reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to changes")

            Text((change.path as NSString).lastPathComponent)
                .font(Token.Type_.tileTitle)
                .lineLimit(1)
                .truncationMode(.head)

            if let diff, !diff.isEmpty, !diff.isBinary {
                Text("+\(diff.additions)")
                    .foregroundStyle(.green)
                Text("−\(diff.deletions)")
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 4)

            // Only offered when a file genuinely has both: a file can be staged AND
            // modified, and one button cannot mean two things.
            if sides.count > 1 {
                Picker("", selection: $side) {
                    ForEach(sides) { Text($0.title).tag($0) }
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
        if isLoading {
            EmptyTileState(icon: "clock", title: "Loading…")
        } else if let diff {
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
            EmptyTileState(icon: "exclamationmark.triangle", title: "Could not read the diff")
        }
    }

    private func reload() async {
        isLoading = true
        diff = await load(side)
        isLoading = false
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
