import Testing
import Foundation
@testable import UltraTerminal
@testable import UltraLayout

/// The keep-awake assertion is only correct if "is an agent running" is correct. Holding a
/// Mac awake for a shell sitting at a prompt would be a battery bug reported as a mystery.
@Suite("Agent activity")
@MainActor
struct AgentActivityTests {

    @Test("a plain shell is not an agent")
    func plainShellDoesNotCount() {
        let factory = ShellPaneFactory(defaultDirectory: NSTemporaryDirectory())
        _ = factory.makeContent(for: PaneID())
        factory.startPendingShells()
        #expect(factory.runningAgentCount == 0,
                "an interactive shell at a prompt is not work")
        for shell in factory.shells.values { shell.stop() }
    }

    @Test("an agent pane counts while it runs, and stops counting once released")
    func agentCounts() {
        let factory = ShellPaneFactory(defaultDirectory: NSTemporaryDirectory())
        factory.stageAgent(AgentDefinition(name: "sleeper", command: "sleep 30"))
        let paneID = PaneID()
        _ = factory.makeContent(for: paneID)
        factory.startPendingShells()
        #expect(factory.runningAgentCount == 1)

        factory.release(paneID)
        #expect(factory.runningAgentCount == 0, "a closed pane holds nothing awake")
    }

    @Test("activity changes are announced, so the assertion can follow them")
    func announcesChanges() {
        let factory = ShellPaneFactory(defaultDirectory: NSTemporaryDirectory())
        var reported: [Int] = []
        factory.onAgentActivityChange = { reported.append($0) }

        factory.stageAgent(AgentDefinition(name: "sleeper", command: "sleep 30"))
        let paneID = PaneID()
        _ = factory.makeContent(for: paneID)
        factory.startPendingShells()
        factory.release(paneID)

        #expect(reported.first == 1, "starting an agent is announced")
        #expect(reported.last == 0, "and so is it going away")
    }
}
