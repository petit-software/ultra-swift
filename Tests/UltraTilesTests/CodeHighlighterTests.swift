import Testing
import Foundation
@testable import UltraTiles

/// The colouriser is one pass and six kinds. These pin the ordering rules that make it look
/// right — a comment swallows quotes, a string swallows keywords — and the detection that
/// picks the table for a file.
@Suite("Code highlighter")
struct CodeHighlighterTests {

    /// A token as its text and kind, so an expectation reads like the source it is about.
    private struct Run: Equatable, CustomStringConvertible {
        let text: String
        let kind: CodeTokenKind
        init(_ text: String, _ kind: CodeTokenKind) { self.text = text; self.kind = kind }
        var description: String { "\(kind):\(text)" }
    }

    private func kinds(_ text: String, _ language: CodeLanguage) -> [Run] {
        CodeHighlighter.tokens(in: text, language: language).map { token in
            Run((text as NSString).substring(with: token.range), token.kind)
        }
    }

    @Test("a language is picked by extension, by well-known name, or not at all")
    func detection() {
        #expect(CodeLanguage.detect(path: "/p/Sources/App.swift")?.name == "Swift")
        #expect(CodeLanguage.detect(path: "Package.SWIFT")?.name == "Swift")
        #expect(CodeLanguage.detect(path: "/p/Makefile")?.name == "Makefile")
        #expect(CodeLanguage.detect(path: "/p/Dockerfile")?.name == "Dockerfile")
        #expect(CodeLanguage.detect(path: "/p/Gemfile")?.name == "Ruby")
        #expect(CodeLanguage.detect(path: "/p/config.yml")?.name == "YAML")
        #expect(CodeLanguage.detect(path: "/p/index.tsx")?.name == "TypeScript")
        #expect(CodeLanguage.detect(path: "/p/notes.md")?.name == "Markdown")
        #expect(CodeLanguage.detect(path: "/p/README")?.name == "Markdown")
        #expect(CodeLanguage.detect(path: "/p/LICENSE") == nil, "prose with no shape is plain")
    }

    @Test("a shebang names the language of a file whose name does not")
    func shebang() {
        #expect(CodeLanguage.detect(shebang: "#!/bin/sh")?.name == "Shell")
        #expect(CodeLanguage.detect(shebang: "#!/usr/bin/env python3")?.name == "Python")
        #expect(CodeLanguage.detect(shebang: "#!/usr/bin/env -S node --harmony")?.name == "JavaScript")
        #expect(CodeLanguage.detect(shebang: "#!/usr/bin/env zsh -f")?.name == "Shell")
        #expect(CodeLanguage.detect(shebang: "# not a shebang") == nil)
        #expect(CodeLanguage.detect(shebang: "") == nil)
    }

    @Test("keywords, types, numbers, strings, comments and attributes, in one Swift line")
    func swiftTokens() {
        let text = "@MainActor let count: Int = 0x1F // \"quoted\" here"
        let found = kinds(text, .swift)
        #expect(found == [
            Run("@MainActor", .attribute),
            Run("let", .keyword),
            Run("Int", .type),
            Run("0x1F", .number),
            Run("// \"quoted\" here", .comment),
        ])
    }

    @Test("a string swallows the keywords and comment markers inside it")
    func stringsWin() {
        let found = kinds(#"print("let // not a comment \" still") // real"#, .swift)
        #expect(found == [
            Run(#""let // not a comment \" still""#, .string),
            Run("// real", .comment),
        ])
    }

    @Test("a block comment spans lines and swallows everything until it closes")
    func blockComment() {
        let text = "/* let x = \"a\"\n   still */ var y"
        let found = kinds(text, .swift)
        #expect(found == [
            Run("/* let x = \"a\"\n   still */", .comment),
            Run("var", .keyword),
        ])
    }

    @Test("an unterminated string stops at the end of its line")
    func unterminatedString() {
        let found = kinds("let s = \"oops\nlet t = 1", .swift)
        #expect(found.map(\.kind) == [.keyword, .string, .keyword, .number])
        #expect(found[1].text == "\"oops", "the next line is code again")
    }

    @Test("a triple-quoted string spans lines where the language has them")
    func tripleQuotes() {
        let text = "x = \"\"\"\nline \"one\"\nline two\n\"\"\"\ny = 2"
        let found = kinds(text, .python)
        #expect(found.first?.kind == .string)
        #expect(found.first?.text.hasSuffix("\"\"\"") == true)
        #expect(found.last == Run("2", .number))
    }

    @Test("a hash is a comment in Python and an attribute in Swift")
    func hashDependsOnLanguage() {
        #expect(kinds("#if DEBUG", .swift).first == Run("#if", .attribute))
        #expect(kinds("x = 1 # note", .python).last == Run("# note", .comment))
    }

    @Test("a word that contains a keyword is not one, and a lowercase name is not a type")
    func wholeWords() {
        let found = kinds("letter classic Foo foo", .swift)
        #expect(found == [Run("Foo", .type)])
    }

    @Test("shell variables are attributes, braces included")
    func shellVariables() {
        let found = kinds("echo \"$HOME\" ${PATH} $1", .shell)
        // Double quotes span lines in shell, and the string swallows `$HOME`.
        #expect(found == [
            Run("echo", .keyword),
            Run("\"$HOME\"", .string),
            Run("${PATH}", .attribute),
            Run("1", .number),
        ])
    }

    @Test("ranges are UTF-16 offsets, so text past an emoji is still placed right")
    func utf16Ranges() {
        let text = "let s = \"🙂\" // c"
        let tokens = CodeHighlighter.tokens(in: text, language: .swift)
        let comment = tokens.last!
        #expect(comment.kind == .comment)
        #expect((text as NSString).substring(with: comment.range) == "// c")
        #expect(comment.range.location + comment.range.length == (text as NSString).length)
    }

    @Test("a table with nothing to say leaves the text plain")
    func plainMarkup() {
        let found = kinds("<div class=\"a\">let</div><!-- x -->", .markup)
        #expect(found == [Run("\"a\"", .string), Run("<!-- x -->", .comment)])
    }
}
