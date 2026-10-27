import Testing
@testable import UltraTerminal

struct ShellQuoteTests {
    @Test("a plain path is left alone")
    func plain() {
        #expect(ShellQuote.escaped("/Users/me/Pictures/shot-2.png") == "/Users/me/Pictures/shot-2.png")
    }

    @Test("spaces, quotes and shell punctuation are backslash-escaped")
    func punctuation() {
        #expect(ShellQuote.escaped("/tmp/Screenshot 2026-10-27 at 10.41.03.png")
                == "/tmp/Screenshot\\ 2026-10-27\\ at\\ 10.41.03.png")
        #expect(ShellQuote.escaped(##"/a/it's (new) [1] $x & y;z*?`~#|<>"\"##)
                == ##"/a/it\'s\ \(new\)\ \[1\]\ \$x\ \&\ y\;z\*\?\`\~\#\|\<\>\"\\"##)
    }

    @Test("a newline in a name survives as a byte the shell reads back")
    func newline() {
        #expect(ShellQuote.escaped("/a/b\nc") == "/a/b$'\\n'c")
    }

    @Test("non-ASCII names are escaped rather than mangled")
    func unicode() {
        #expect(ShellQuote.escaped("/a/café é.png") == "/a/caf\\é\\ \\é.png")
    }

    @Test("a dropped line is the paths, spaced, with room to keep typing")
    func line() {
        #expect(ShellQuote.line(["/a/one.png", "/b/two three.png"]) == "/a/one.png /b/two\\ three.png ")
        #expect(ShellQuote.line([]) == "")
    }
}
