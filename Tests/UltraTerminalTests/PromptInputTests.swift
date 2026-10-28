import Testing
@testable import UltraTerminal

/// The `@` and `/` pickers open only at the start of a line, and the start of a line is
/// read from the screen: what is drawn on the caret's row before the caret.
@Suite("Prompt line start")
struct PromptInputTests {
    @Test("an empty prompt: a marker, a box, or nothing at all")
    func emptyPrompts() {
        #expect(PromptInput.isLineStart(before: ""))
        #expect(PromptInput.isLineStart(before: "❯ "))
        #expect(PromptInput.isLineStart(before: "> "))
        #expect(PromptInput.isLineStart(before: "› "))
        #expect(PromptInput.isLineStart(before: "│ > "))
        #expect(PromptInput.isLineStart(before: "  "), "a continuation line, indented")
        #expect(PromptInput.isLineStart(before: "\u{0}\u{0}❯ "), "empty cells read as NUL")
    }

    @Test("anything typed after the marker is a line being written")
    func typedLines() {
        #expect(!PromptInput.isLineStart(before: "❯ hello"))
        #expect(!PromptInput.isLineStart(before: "❯ @"), "the trigger typed literally")
        #expect(!PromptInput.isLineStart(before: "> /"))
        #expect(!PromptInput.isLineStart(before: "❯ 1"))
        #expect(!PromptInput.isLineStart(before: "cd "))
        #expect(!PromptInput.isLineStart(before: "a"))
        #expect(!PromptInput.isLineStart(before: "│ > look at "))
    }
}
