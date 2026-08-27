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

    // MARK: - Working directory

    @Test("our own process reports the directory we are actually in")
    func readsOwnWorkingDirectory() {
        let reported = ForegroundProcess.workingDirectory(ofProcess: getpid())
        #expect(reported != nil)
        // /tmp and /var are symlinks on macOS and the kernel answers with the resolved path,
        // so the two sides are resolved before comparing rather than compared as typed.
        let actual = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        #expect(reported.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == actual)
    }

    /// The whole point: a shell that has cd'd reports where it went, with no OSC 7 and no
    /// cooperation from the shell's configuration.
    @Test("a child that has cd'd reports its new directory, not the one it was launched in")
    func followsAChildsCd() throws {
        let launched = FileManager.default.temporaryDirectory
        let moved = URL(fileURLWithPath: "/usr/lib")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cd \(moved.path) && sleep 5"]
        process.currentDirectoryURL = launched
        try process.run()
        defer { process.terminate() }

        // The `cd` happens in the child's own time; poll rather than guess a sleep long
        // enough, so a loaded machine does not fail this for being slow.
        var reported: String?
        for _ in 0..<100 {
            reported = ForegroundProcess.workingDirectory(ofProcess: process.processIdentifier)
            if reported == moved.path { break }
            usleep(20_000)
        }
        #expect(reported == moved.path)
    }

    /// Panes are probed while they are being torn down, so a dead or impossible pid has to
    /// answer nil rather than trap or hand back a half-filled path.
    @Test("a pid that cannot exist reports no directory")
    func unknownPidHasNoDirectory() {
        #expect(ForegroundProcess.workingDirectory(ofProcess: pid_t(Int32.max)) == nil)
        #expect(ForegroundProcess.workingDirectory(ofProcess: 0) == nil)
        #expect(ForegroundProcess.workingDirectory(ofProcess: -1) == nil)
    }
}
