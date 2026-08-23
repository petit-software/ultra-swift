import Darwin
import Foundation

/// What a pane is actually doing right now, read from its pty rather than from what the app
/// remembers launching.
public struct PaneActivity: Equatable, Sendable {
    /// The executable in the tty's foreground process group — "zsh", "claude", "vim".
    public var command: String
    /// Whether that executable is one of the known agents.
    public var isAgent: Bool

    public init(command: String, isAgent: Bool) {
        self.command = command
        self.isAgent = isAgent
    }
}

/// Reads the foreground process of a pseudo-terminal.
///
/// Launch-time bookkeeping — "this pane counts as an agent because we started it as one" —
/// is blind to the way agents are usually started, which is typing `claude` at a prompt. It
/// also cannot see one EXIT: the pane goes on counting as an agent while a shell sits at a
/// prompt doing nothing, which is exactly the case the keep-awake assertion must not hold
/// the machine open for.
///
/// The tty knows. `tcgetpgrp` returns the process group the terminal is currently giving
/// input to, which is the definition of "in the foreground", and one `proc_pidpath` turns
/// that into a name. Two syscalls, no `ps` fork.
public enum ForegroundProcess {

    /// The foreground process group's executable name, or nil if the fd is not a terminal or
    /// has no foreground group — a shell that has already exited, most often.
    public static func name(ofTerminal fd: Int32) -> String? {
        guard fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        guard group > 0 else { return nil }
        return name(ofProcess: group)
    }

    /// The last path component of a pid's executable.
    ///
    /// The process group id doubles as the pid of its leader, which is the process the
    /// shell put in the foreground — so no group walk is needed.
    public static func name(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(cString: buffer)
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// What this terminal is doing, classified against the agents that are known.
    ///
    /// Matching is on the executable's NAME, because that is all the tty can offer, and it is
    /// compared against each agent's `binary` — the first word of its command line, which is
    /// the same string `which` is given when probing availability.
    public static func activity(ofTerminal fd: Int32,
                                agents: [AgentDefinition] = AgentDefinition.builtIns) -> PaneActivity? {
        guard let command = name(ofTerminal: fd) else { return nil }
        return PaneActivity(command: command, isAgent: isAgent(command, in: agents))
    }

    /// Is this executable one of the known agents?
    ///
    /// An agent's `binary` can be a path (`/usr/local/bin/claude`) or bare (`claude`), and
    /// the tty only ever reports a bare name — so both sides are reduced to a last path
    /// component before comparing. Without that, an agent configured with an absolute path
    /// would never be recognised while running, which is a silent half-failure: the pane
    /// works, and simply never reports itself as an agent.
    public static func isAgent(_ command: String,
                               in agents: [AgentDefinition] = AgentDefinition.builtIns) -> Bool {
        let name = (command as NSString).lastPathComponent
        guard !name.isEmpty else { return false }
        return agents.contains { ($0.binary as NSString).lastPathComponent == name }
    }
}
