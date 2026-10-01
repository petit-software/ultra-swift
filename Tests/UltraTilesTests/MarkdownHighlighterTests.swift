import Testing
import Foundation
@testable import UltraTiles

/// Markdown is coloured by its structure, a line at a time. These pin the rules that make
/// it read right: a fence swallows what is inside it, a code span swallows emphasis marks,
/// an underscore inside a name is not emphasis.
@Suite("Markdown highlighter")
struct MarkdownHighlighterTests {

    private struct Run: Equatable, CustomStringConvertible {
        let text: String
        let kind: CodeTokenKind
        init(_ text: String, _ kind: CodeTokenKind) { self.text = text; self.kind = kind }
        var description: String { "\(kind):\(text)" }
    }

    private func runs(_ text: String) -> [Run] {
        CodeHighlighter.tokens(in: text, language: .markdown).map { token in
            Run((text as NSString).substring(with: token.range), token.kind)
        }
    }

    @Test("a heading is its whole line, from one hash to six")
    func headings() {
        #expect(runs("# Title\n## Sub\n###### Six\n####### Not one\n#NotOne") ==
                [Run("# Title", .heading), Run("## Sub", .heading), Run("###### Six", .heading)])
    }

    @Test("a paragraph underlined with === or --- is a heading, both lines")
    func setextHeadings() {
        #expect(runs("Title\n=====\n\nSub\n---\n") ==
                [Run("Title", .heading), Run("=====", .heading), Run("Sub", .heading), Run("---", .heading)])
    }

    @Test("a rule on its own is a marker, not a heading")
    func rules() {
        #expect(runs("\n---\n* * *\n___\n") ==
                [Run("---", .marker), Run("* * *", .marker), Run("___", .marker)])
    }

    @Test("a fenced block is code, fences included, and a hash inside it is not a heading")
    func fences() {
        let text = "```sh\n# not a heading\necho *hi*\n```\n# heading"
        #expect(runs(text) == [Run("```sh", .marker), Run("# not a heading", .code),
                               Run("echo *hi*", .code), Run("```", .marker), Run("# heading", .heading)])
    }

    @Test("a tilde fence closes only on tildes, and an unclosed fence runs to the end")
    func tildeFence() {
        #expect(runs("~~~\n```\nstill code") ==
                [Run("~~~", .marker), Run("```", .code), Run("still code", .code)])
    }

    @Test("strong and emphasis, with either mark, marks included")
    func emphasis() {
        #expect(runs("a **strong** and *soft* and __strong__ and _soft_ word") ==
                [Run("**strong**", .strong), Run("*soft*", .emphasis),
                 Run("__strong__", .strong), Run("_soft_", .emphasis)])
    }

    @Test("an underscore inside a name is not emphasis, and a lone star is a star")
    func underscoresInNames() {
        #expect(runs("snake_case_name and 2 * 3 * 4").isEmpty)
    }

    @Test("a code span swallows the emphasis marks inside it, and closes at its own length")
    func codeSpans() {
        #expect(runs("use `*args*` and `` a`b `` here") ==
                [Run("`*args*`", .code), Run("`` a`b ``", .code)])
        #expect(runs("an unclosed `span stays *plain*") == [Run("*plain*", .emphasis)])
    }

    @Test("a link is its text, and its destination recedes")
    func links() {
        #expect(runs("see [the docs](https://example.com/x) and ![a cat](cat.png) and [ref][1]") ==
                [Run("[the docs]", .link), Run("(https://example.com/x)", .comment),
                 Run("![a cat]", .link), Run("(cat.png)", .comment), Run("[ref][1]", .link)])
        #expect(runs("[1]: https://example.com\n") ==
                [Run("[1]:", .link), Run(" https://example.com", .comment)])
    }

    @Test("a bare or bracketed URL is a link, without the sentence's full stop")
    func bareURLs() {
        #expect(runs("go to https://example.com/a. Or <https://b.io>!") ==
                [Run("https://example.com/a", .link), Run("<https://b.io>", .link)])
    }

    @Test("bullets, numbers and task boxes are markers, and the item's text is scanned")
    func lists() {
        #expect(runs("- one\n* two\n+ three\n12. twelve\n3) three\n- [ ] todo **now**\n- [x] done\n-not a list") ==
                [Run("-", .marker), Run("*", .marker), Run("+", .marker), Run("12.", .marker),
                 Run("3)", .marker), Run("-", .marker), Run("[ ]", .marker), Run("**now**", .strong),
                 Run("-", .marker), Run("[x]", .marker)])
    }

    @Test("a quote's marks are markers, however deep, and what follows is scanned")
    func quotes() {
        #expect(runs("> quoted *word*\n> > deeper") ==
                [Run(">", .marker), Run("*word*", .emphasis), Run("> >", .marker)])
    }

    @Test("front matter on the first line is a comment through its closing dashes")
    func frontMatter() {
        #expect(runs("---\ntitle: x\n---\n# Head\n---") ==
                [Run("---", .comment), Run("title: x", .comment), Run("---", .comment),
                 Run("# Head", .heading), Run("---", .marker)])
    }

    @Test("an HTML comment is a comment, on one line or across several")
    func htmlComments() {
        #expect(runs("a <!-- b --> c") == [Run("<!-- b -->", .comment)])
        #expect(runs("<!-- open\n# not a heading\nclose --> *em*") ==
                [Run("<!-- open", .comment), Run("# not a heading", .comment),
                 Run("close -->", .comment), Run("*em*", .emphasis)])
    }

    @Test("ranges are UTF-16 offsets, so text past an emoji is still placed right")
    func utf16Ranges() {
        let text = "🙂 **bold**"
        let token = CodeHighlighter.tokens(in: text, language: .markdown).first
        #expect(token?.range == NSRange(location: 3, length: 8))
    }

    @Test("a CRLF file is read line by line too")
    func crlf() {
        #expect(runs("# A\r\n- b\r\n") == [Run("# A", .heading), Run("-", .marker)])
    }
}
