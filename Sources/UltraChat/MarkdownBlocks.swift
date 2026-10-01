import Foundation

/// A model's answer, cut into the pieces a chat renders differently.
///
/// Fenced code is the one thing Foundation's Markdown parser cannot do — it flattens a
/// block into a run of text — and the one thing a terminal's chat pane cares most about,
/// since a code block is what gets sent to the shell. Headings and lists it leaves as the
/// literal `##` and `-` they were typed with, so those are cut out here too: a list is
/// drawn with bullets, and a heading as its own line. What is left is prose, one paragraph
/// per block, which the parser does well — emphasis, links and inline code.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case heading(String)
    case list([MarkdownListItem])
    case code(language: String?, text: String)
}

/// One item of a list. `ordinal` is the number as written ("1.", "2)"), or nil for a
/// bullet; `depth` is how far it was indented, two spaces or a tab per level.
public struct MarkdownListItem: Equatable, Sendable {
    public var text: String
    public var ordinal: String?
    public var depth: Int

    public init(_ text: String, ordinal: String? = nil, depth: Int = 0) {
        self.text = text
        self.ordinal = ordinal
        self.depth = depth
    }
}

public enum MarkdownBlocks {

    /// Split on fences, then cut what is between them into paragraphs, headings and
    /// lists. A fence still open when the text ends — which is every moment of a streaming
    /// answer that is midway through a code block — closes at the end, so the block renders
    /// as code while it is arriving rather than as prose that snaps into a box when the
    /// closing fence lands.
    public static func split(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var fence: Substring?

        func flushProse() {
            blocks += paragraphs(prose)
            prose = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(open) {
                    blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                    code = []
                    fence = nil
                    language = nil
                } else {
                    code.append(line)
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let marker = trimmed.prefix(3)
                fence = marker
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                language = info.isEmpty ? nil : String(info.split(separator: " ").first ?? "")
            } else {
                prose.append(line)
            }
        }
        if fence != nil {
            blocks.append(.code(language: language, text: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return blocks
    }

    /// The lines between two fences as blocks. A blank line ends a paragraph; a heading
    /// is a block of its own; list lines in a row are one list, and a blank line inside a
    /// list does not end it as long as a list line follows. An indented line under a list
    /// item is the rest of that item.
    static func paragraphs(_ lines: [Substring]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var items: [MarkdownListItem] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            paragraph = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)) }
            items = []
        }

        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                // Items separated by blank lines are still one list; a blank line before
                // anything else is where the list ends.
                if !items.isEmpty, let next = lines[index...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   listItem(next) == nil {
                    flushList()
                }
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                items.append(item)
                continue
            }
            if !items.isEmpty, line.first?.isWhitespace == true {
                // The rest of the item above, wrapped onto its own line.
                items[items.count - 1].text += " " + trimmed
                continue
            }
            flushList()
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        flushList()
        return blocks
    }

    /// `## Title` → "Title". Up to six hashes, then a space: `#hashtag` is prose.
    private static func heading(_ trimmed: String) -> String? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// `- a`, `* a`, `+ a`, `1. a`, `1) a`, with any indentation. A `-` or `1.` on its own,
    /// or run into the word after it, is prose; `--flag` and `3.14` are not list items.
    private static func listItem(_ line: Substring) -> MarkdownListItem? {
        var depth = 0
        var rest = line[...]
        while let first = rest.first, first == " " || first == "\t" {
            depth += first == "\t" ? 2 : 1
            rest = rest.dropFirst()
        }
        var ordinal: String?
        if let first = rest.first, "-*+".contains(first) {
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let afterDigits = rest.dropFirst(digits.count)
            guard let punct = afterDigits.first, punct == "." || punct == ")" else { return nil }
            ordinal = String(digits) + String(punct)
            rest = afterDigits.dropFirst()
        }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(text, ordinal: ordinal, depth: depth / 2)
    }
}
