import Foundation
import Testing
@testable import UltraChat

/// What the copy icon under an answer puts on the clipboard.
@Suite("Answer text")
struct AnswerTextTests {
    private let question = ChatMessage(role: .user, text: "Why?")

    @Test("every turn of the answer, a paragraph apart, without the tool calls")
    func wholeAnswer() {
        let messages = [
            question,
            ChatMessage(role: .assistant, text: "Let me look.\n",
                        toolCalls: [ChatToolCall(id: "r", name: "Read", arguments: "{}", result: "…")]),
            ChatMessage(role: .assistant, text: "", toolCalls: [ChatToolCall(id: "s", name: "Grep", arguments: "{}", result: "…")]),
            ChatMessage(role: .assistant, text: "Because."),
        ]
        #expect(ChatMessage.answerText(endingAt: 3, in: messages) == "Let me look.\n\nBecause.")
    }

    @Test("only the message that ends an answer has one")
    func onlyAtTheEnd() {
        let messages = [
            question,
            ChatMessage(role: .assistant, text: "One"),
            ChatMessage(role: .assistant, text: "Two"),
            ChatMessage(role: .user, text: "And?"),
            ChatMessage(role: .assistant, text: "Three"),
        ]
        #expect(ChatMessage.answerText(endingAt: 0, in: messages) == nil)
        #expect(ChatMessage.answerText(endingAt: 1, in: messages) == nil)
        #expect(ChatMessage.answerText(endingAt: 2, in: messages) == "One\n\nTwo")
        #expect(ChatMessage.answerText(endingAt: 4, in: messages) == "Three")
        #expect(ChatMessage.answerText(endingAt: 9, in: messages) == nil)
    }

    @Test("an answer that said nothing has nothing to copy")
    func silent() {
        let messages = [question, ChatMessage(role: .assistant, text: "  \n")]
        #expect(ChatMessage.answerText(endingAt: 1, in: messages) == nil)
    }
}
