import MarkdownUI
import SwiftUI
import UltraDesign

/// A Markdown file as the page it describes, rather than as the text it is written in.
///
/// The editor's other face for the one file kind that has two: a README is opened to be
/// read far more often than to be edited, and read as `##` and `**` it is a page seen
/// through its own scaffolding. `EditorDocument.isReading` says which face is showing;
/// the footer's pencil and book, and Pane ▸ Editor ▸ Toggle Reading Mode, switch it.
///
/// Drawn by MarkdownUI with GitHub's layout — the look every README was written to be
/// read in — in the pane's own colours, so a pane pinned light reads light and the glass
/// shows through. Links open where links open; images beside the file are found beside
/// the file. The text itself is left alone: this is a view of the buffer, so a change on
/// disk that the document reloads is redrawn here too.
struct MarkdownReadingView: View {
    let text: String
    /// Where the file is, so `docs/plan.md` and `./diagram.png` resolve next to it.
    let url: URL

    var body: some View {
        ScrollView {
            Markdown(text, baseURL: url, imageBaseURL: url)
                .markdownTheme(.ultraReading)
                .markdownCodeSyntaxHighlighter(EditorCodeSyntaxHighlighter())
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                // A measure, not the pane: a line of prose across a 1400pt pane is not
                // readable, and GitHub stops its pages at about this width for the same
                // reason. Left-aligned, so a narrow pane and a wide one start the text
                // in the same place.
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Theme {
    /// GitHub's Markdown — headings ruled, code boxed, tables lined — in the pane's own
    /// colours and the editor's size. The GitHub theme paints the page white or GitHub's
    /// own near-black over the pane, which is what `text` is replaced to undo: no
    /// background, the label colour, 14pt rather than a browser's 16.
    ///
    /// On the main actor rather than a plain static: a theme is a bag of view-building
    /// closures and is not `Sendable`, and every reader is a view body.
    @MainActor static let ultraReading = Theme.gitHub
        .text {
            ForegroundColor(Token.Colour.label)
            FontSize(14)
        }
}

/// Fenced code on a page, coloured the way the same code is in the editor's text view —
/// the same table of languages, the same system colours — so a `swift` block reads the
/// same on both faces of the file. A fence in a language the table does not know is
/// plain, as it is in the editor.
struct EditorCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        guard let language = language.flatMap(Self.language(named:)) else { return Text(code) }
        let source = code as NSString
        var result = Text("")
        var cursor = 0
        for token in CodeHighlighter.tokens(in: code, language: language)
        where token.range.location >= cursor && NSMaxRange(token.range) <= source.length {
            if token.range.location > cursor {
                result = result + Text(source.substring(with: NSRange(location: cursor,
                                                                      length: token.range.location - cursor)))
            }
            result = result + Text(source.substring(with: token.range))
                .foregroundStyle(Color(nsColor: CodeTextView.Coordinator.colour(for: token.kind)))
            cursor = NSMaxRange(token.range)
        }
        if cursor < source.length { result = result + Text(source.substring(from: cursor)) }
        return result
    }

    /// The language a fence's label names. Labels are extensions as often as names —
    /// `swift`, `py`, `sh`, `json` — and names as often as extensions — `python`, `bash`,
    /// `ruby` — so both of the editor's own detections are tried, by a made-up file name
    /// and by a made-up shebang.
    static func language(named hint: String) -> CodeLanguage? {
        let hint = hint.trimmingCharacters(in: .whitespaces).lowercased()
        guard !hint.isEmpty else { return nil }
        return CodeLanguage.detect(path: "fence.\(hint)")
            ?? CodeLanguage.detect(shebang: "#!/usr/bin/env \(hint)")
    }
}

#Preview("Reading a README", traits: .fixedLayout(width: 620, height: 480)) {
    MarkdownReadingView(text: """
        # Ultra

        A Mac terminal with **panes** beside the shell. See [the overview](docs/00-OVERVIEW.md).

        ## Today
        - [x] Open a Markdown file as a page
        - [ ] Edit it with one click

        | Key | Does |
        | --- | --- |
        | ⌃⌘R | Toggle reading mode |

        ```swift
        let page = MarkdownReadingView(text: "# Hello", url: url)
        ```

        > A quote, for the shape of one.
        """, url: URL(fileURLWithPath: "/tmp/README.md"))
}
