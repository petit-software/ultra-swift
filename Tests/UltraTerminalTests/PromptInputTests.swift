import Testing
@testable import UltraTerminal

/// The `@` and `/` pickers open only at the start of a line. The terminal cannot see the
/// agent's caret, so it counts what the user sent — and the count must be zero exactly
/// when the line is empty.
@Suite("Prompt input length")
struct PromptInputTests {
    private func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    @Test("typing counts up, Return resets")
    func typingAndReturn() {
        var length = PromptInput.length(after: bytes("hello"), from: 0)
        #expect(length == 5)
        length = PromptInput.length(after: bytes("\r"), from: length)
        #expect(length == 0)
    }

    @Test("backspace counts down and never below zero")
    func backspace() {
        var length = PromptInput.length(after: bytes("ab"), from: 0)
        length = PromptInput.length(after: [0x7f], from: length)
        #expect(length == 1)
        length = PromptInput.length(after: [0x7f, 0x7f, 0x08], from: length)
        #expect(length == 0)
    }

    @Test("^C and ^U clear the line, as they do in every agent and shell")
    func controlClears() {
        #expect(PromptInput.length(after: [0x03], from: 7) == 0)
        #expect(PromptInput.length(after: [0x15], from: 7) == 0)
    }

    @Test("an escape sequence — an arrow key — is not typing")
    func escapeSequences() {
        #expect(PromptInput.length(after: bytes("\u{1b}[A"), from: 0) == 0)
        #expect(PromptInput.length(after: bytes("\u{1b}[D"), from: 3) == 3)
    }

    @Test("a pasted or injected chunk counts every character")
    func injected() {
        #expect(PromptInput.length(after: bytes("@Sources/App.swift "), from: 0) == 19)
    }
}
