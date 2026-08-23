import Testing
import Darwin
import Foundation
@testable import UltraTerminal

/// Agent state read from the tty rather than from what the app remembers launching.
///
/// The old answer — "this pane counts as an agent because we started it as one" — was blind
/// to `claude` typed at a prompt, which is how agents are usually started, and could not see
/// one exit: a shell back at its prompt went on counting, holding the keep-awake assertion
/// open for nothing.
@Suite("Foreground process")
struct ForegroundProcessTests {

    @Test("our own process reports its own name")
    func namesThisProcess() {
        let name = ForegroundProcess.name(ofProcess: getpid())
        #expect(name != nil)
        #expect(name?.isEmpty == false)
    }

    @Test("a pid that cannot exist reports nothing, rather than an empty name")
    func unknownPidIsNil() {
        #expect(ForegroundProcess.name(ofProcess: pid_t(Int32.max)) == nil)
    }

    /// A closed or non-tty descriptor must answer nil rather than trapping — panes are asked
    /// for their activity on a timer, including while one is being torn down.
    @Test("a descriptor that is not a terminal is nil, not a crash")
    func nonTerminalIsNil() {
        #expect(ForegroundProcess.name(ofTerminal: -1) == nil)
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        #expect(ForegroundProcess.name(ofTerminal: fd) == nil)
    }

    @Test("the built-in agents are recognised by name")
    func recognisesBuiltIns() {
        #expect(ForegroundProcess.isAgent("claude"))
        #expect(ForegroundProcess.isAgent("codex"))
    }

    @Test("a plain shell is not an agent")
    func shellIsNotAnAgent() {
        #expect(!ForegroundProcess.isAgent("zsh"))
        #expect(!ForegroundProcess.isAgent("bash"))
        #expect(!ForegroundProcess.isAgent("vim"))
    }

    /// The tty reports a bare executable name, but an agent can be configured with an
    /// absolute path. Comparing the two unreduced would never match, and the pane would work
    /// while silently never reporting itself as an agent.
    @Test("an agent configured with a full path still matches the bare name from the tty")
    func absolutePathAgentMatches() {
        let agents = [AgentDefinition(name: "Claude", command: "/opt/homebrew/bin/claude --resume")]
        #expect(ForegroundProcess.isAgent("claude", in: agents))
        #expect(ForegroundProcess.isAgent("/opt/homebrew/bin/claude", in: agents))
    }

    @Test("an empty name matches nothing")
    func emptyMatchesNothing() {
        #expect(!ForegroundProcess.isAgent(""))
    }

    @Test("an agent list that is empty recognises nothing, rather than everything")
    func emptyAgentListMatchesNothing() {
        #expect(!ForegroundProcess.isAgent("claude", in: []))
    }
}
