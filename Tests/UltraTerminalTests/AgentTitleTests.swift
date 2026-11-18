import Testing
@testable import UltraTerminal

@Suite struct AgentTitleTests {
    @Test func dropsTheStatusGlyph() {
        #expect(AgentTitle.active("✳ Fix the orders 404") == "Fix the orders 404")
        #expect(AgentTitle.active("⠐ Fix the orders 404") == "Fix the orders 404")
        #expect(AgentTitle.active("⠂ Fix the orders 404") == AgentTitle.active("✳ Fix the orders 404"))
        #expect(AgentTitle.active("* Review PR 12") == "Review PR 12")
    }

    @Test func keepsATitleThatStartsWithPunctuationOfItsOwn() {
        #expect(AgentTitle.active("~/Repo/ultra") == "~/Repo/ultra")
        #expect(AgentTitle.active("[draft] Release notes") == "[draft] Release notes")
    }

    @Test func nothingWhenThereIsNoTitle() {
        #expect(AgentTitle.active(nil) == nil)
        #expect(AgentTitle.active("") == nil)
        #expect(AgentTitle.active("✳ ") == nil)
    }

    @Test func theAgentsOwnNameIsNotATitle() {
        #expect(AgentTitle.active("✳ Claude Code", agentName: "Claude Code") == nil)
        #expect(AgentTitle.active("claude code", agentName: "Claude Code") == nil)
        #expect(AgentTitle.active("✳ Claude Code tips", agentName: "Claude Code") == "Claude Code tips")
    }
}
