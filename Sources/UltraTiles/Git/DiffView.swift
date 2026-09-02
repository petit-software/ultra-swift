import AppKit
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
            //
            // Pills rather than the segmented picker this was: a segmented control brings its
            // own opaque bezel, and in a header floating on a pane's glass that read as a
            // control panel screwed to the surface — at a fixed 190pt, which is most of a
            // narrow pane's width. `PillTabs` at `.small` is the same switch in the same type
            // as the path and the counts beside it. See `PillTabs`.
            if session.sides.count > 1 {
                PillTabs(session.sides, selection: $session.side, size: .small) { $0.title }
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
                // The pane's width has to be KNOWN here, and that is what the geometry reader
                // is for. Every row is then given the same width, at least the width of the
                // pane — see `rowWidth`.
                GeometryReader { geometry in
                    let width = rowWidth(for: diff, viewport: geometry.size.width)
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.hunks) { hunk in
                                HunkHeader(hunk: hunk, width: width)
                                ForEach(hunk.lines) { DiffLineRow(line: $0, width: width) }
                            }
                        }
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    }
                }
            }
        } else {
            // Nothing loaded YET rather than nothing to load: the first fetch is the only
            // time this shows, because a reload keeps the previous diff on screen while it
            // runs rather than flashing the pane empty.
            EmptyTileState(icon: "clock", title: "Loading…")
        }
    }

    /// The width every row is given: the pane, or the longest line, whichever is wider.
    ///
    /// ONE width for all of them, and that is what fixes two things at once. A row was
    /// previously as wide as its own text, so the stack of them was as wide as the longest
    /// line — and a horizontal `ScrollView` CENTRES content narrower than itself, which is
    /// why a diff of short lines showed up as a narrow column floating in the middle of the
    /// editor. The same fact left the green and red washes stopping where each line's text
    /// stopped, in a ragged edge down the middle of the pane, instead of marking the line.
    ///
    /// A minimum rather than an exact size, so a line longer than the estimate simply makes
    /// its own row wider and scrolls, instead of being truncated by a frame that claimed to
    /// know better.
    private func rowWidth(for diff: FileDiff, viewport: CGFloat) -> CGFloat {
        max(viewport, DiffMetrics.gutter + CGFloat(diff.columns) * DiffMetrics.advance)
    }
}

/// The diff's row geometry, in one place — the gutter's parts, and how wide a character is.
private enum DiffMetrics {
    static let textSize: CGFloat = 11
    static let numberSize: CGFloat = 10
    static let numberWidth: CGFloat = 34
    static let numberGap: CGFloat = 4
    static let signWidth: CGFloat = 14
    static let rowPadding: CGFloat = 6

    /// Everything to the left of the text: two line numbers, the sign, and the row's padding.
    static var gutter: CGFloat { 2 * (numberWidth + numberGap) + signWidth + 2 * rowPadding }

    /// One character's advance, measured once. The rows are monospaced, so this is the only
    /// measurement a row width needs — see `DiffView.rowWidth`.
    static let advance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: textSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()
}

private struct HunkHeader: View {
    let hunk: DiffHunk
    /// The width shared by every row — see `DiffView.rowWidth`.
    let width: CGFloat

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
        // BEFORE the background, so the band runs the full width of the pane. A hunk header
        // that stopped where its own text stopped was a grey tab, not a rule.
        .frame(minWidth: width, alignment: .leading)
        .background(Token.Colour.label.opacity(0.05))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    /// The width shared by every row — see `DiffView.rowWidth`.
    let width: CGFloat

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
                .frame(width: DiffMetrics.signWidth)
            emphasised
                .foregroundStyle(line.kind == .marker ? Token.Colour.tertiaryLabel
                                                      : Token.Colour.label)
            Spacer(minLength: 0)
        }
        .font(.system(size: DiffMetrics.textSize, design: .monospaced))
        .padding(.horizontal, DiffMetrics.rowPadding)
        // BEFORE the background: the wash marks the LINE, so it runs the width of the pane.
        .frame(minWidth: width, alignment: .leading)
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
            .font(.system(size: DiffMetrics.numberSize, design: .monospaced))
            .foregroundStyle(Token.Colour.tertiaryLabel)
            .frame(width: DiffMetrics.numberWidth, alignment: .trailing)
            .padding(.trailing, DiffMetrics.numberGap)
    }
}
