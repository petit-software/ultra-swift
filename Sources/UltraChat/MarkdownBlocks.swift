import Foundation

/// A model's answer, cut into the pieces a chat renders differently.
///
/// Only two kinds, on purpose. Prose is handed to Foundation's own Markdown parser, which
/// does emphasis, links and inline code well. Fenced code is the one thing it cannot do —
/// it flattens a block into a run of text — and the one thing a terminal's chat pane
/// cares most about, since a code block is what gets sent to the shell.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String?, text: String)
}

public enum MarkdownBlocks {

    /// Split on fences. A fence still open when the text ends — which is every moment of a
    /// streaming answer that is midway through a code block — closes at the end, so the
    /// block renders as code while it is arriving rather than as prose that snaps into a
    /// box when the closing fence lands.
    public static func split(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var fence: Substring?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
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
}
