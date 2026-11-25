import Testing
@testable import UltraTerminal

/// A pane's screen cut down for the answer window: the words without the drawing.
@Suite("Answer screen")
struct AnswerScreenTests {

    @Test("a boxed question loses its box and keeps the choices' alignment")
    func boxed() {
        let screen = """
        ⏺ I'll remove the build folder.
        ╭──────────────────────────────────────────────────────────────╮
        │ Bash command                                                 │
        │                                                              │
        │   rm -rf build                                               │
        │                                                              │
        │ Do you want to proceed?                                      │
        │ ❯ 1. Yes                                                     │
        │   2. No, and tell Claude what to do differently (esc)        │
        ╰──────────────────────────────────────────────────────────────╯
        """.components(separatedBy: "\n")
        #expect(AnswerScreen.lines(from: screen) == [
            "⏺ I'll remove the build folder.",
            "",
            "Bash command",
            "",
            "  rm -rf build",
            "",
            "Do you want to proceed?",
            "❯ 1. Yes",
            "  2. No, and tell Claude what to do differently (esc)",
        ])
    }

    @Test("rules around a prompt become one gap, and trailing gaps go")
    func rules() {
        let screen = ["  Done. The tests pass.", "", "",
                      "────────────────────────────────", "  ❯ ", "────────────────────────────────",
                      "  ? for shortcuts", "", ""]
        #expect(AnswerScreen.lines(from: screen) == ["Done. The tests pass.", "", "❯", "", "? for shortcuts"])
    }

    @Test("only the last rows are kept, and an empty screen is nothing")
    func limited() {
        let screen = (1...30).map { "line \($0)" }
        #expect(AnswerScreen.lines(from: screen, limit: 3) == ["line 28", "line 29", "line 30"])
        #expect(AnswerScreen.lines(from: []) == [])
        #expect(AnswerScreen.lines(from: ["", "──────", ""]) == [])
    }
}
