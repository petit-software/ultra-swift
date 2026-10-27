import Darwin
import Foundation
import UltraCore

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
        executablePath(ofTerminal: fd).map { ($0 as NSString).lastPathComponent }
    }

    /// The foreground process group's executable, as a full path, or nil as above.
    public static func executablePath(ofTerminal fd: Int32) -> String? {
        guard fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        guard group > 0 else { return nil }
        return executablePath(ofProcess: group)
    }

    /// The last path component of a pid's executable.
    ///
    /// The process group id doubles as the pid of its leader, which is the process the
    /// shell put in the foreground — so no group walk is needed.
    public static func name(ofProcess pid: pid_t) -> String? {
        executablePath(ofProcess: pid).map { ($0 as NSString).lastPathComponent }
    }

    /// A pid's executable, as a full path, from the kernel.
    public static func executablePath(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(cString: buffer)
        return (path as NSString).lastPathComponent.isEmpty ? nil : path
    }

    /// Where a process actually is, read from the kernel rather than from the shell.
    ///
    /// OSC 7 is the well-behaved way to learn this, and on a stock macOS nothing emits it:
    /// the hook that does lives in `/etc/zshrc_Apple_Terminal`, and `/etc/zshrc` sources it
    /// only when `$TERM_PROGRAM` is `Apple_Terminal`. So a pane's header froze at the
    /// directory it was launched in and stayed there for the whole session, however far the
    /// user cd'd. Claiming to be Terminal.app to unlock the hook would put a lie in the
    /// environment of every process the pane ever spawns, to fix a header.
    ///
    /// The kernel already knows. `proc_pidinfo` reads the process's own current directory,
    /// which needs no cooperation from zsh, bash, fish, or anything else the user runs.
    /// Nil for a pid that has exited, or one we may not look at.
    public static func workingDirectory(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        // A short read means the struct was not filled in — a partially populated path is
        // not a directory anyone should be shown.
        guard written == size else { return nil }
        var path = info.pvi_cdir.vip_path
        let cwd = withUnsafeBytes(of: &path) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
        }
        return cwd.isEmpty ? nil : cwd
    }

    /// What this terminal is doing, classified against the agents that are known.
    ///
    /// Matching is on the executable's NAME, because that is all the tty can offer, and it is
    /// compared against each agent's `binary` — the first word of its command line, which is
    /// the same string `which` is given when probing availability.
    public static func activity(ofTerminal fd: Int32,
                                agents: [AgentDefinition] = AgentDefinition.known) -> PaneActivity? {
        guard let path = executablePath(ofTerminal: fd) else { return nil }
        return activity(forExecutable: path, in: agents)
    }

    /// What an executable path says the pane is doing: the agent it belongs to, by the
    /// agent's bare binary name, or the executable's own name for anything else.
    ///
    /// The agent's name rather than the file's, and that is the point: Claude Code's
    /// native install runs `~/.local/share/claude/versions/2.1.311`, and a pane reporting
    /// "2.1.311 is waiting" is a pane reporting a number nobody can place.
    public static func activity(forExecutable path: String,
                                in agents: [AgentDefinition] = AgentDefinition.known) -> PaneActivity {
        if let agent = agent(forExecutable: path, in: agents) {
            return PaneActivity(command: agent.binaryName, isAgent: true)
        }
        return PaneActivity(command: (path as NSString).lastPathComponent, isAgent: false)
    }

    /// Is this executable one of the known agents? See `agent(forExecutable:in:)`.
    public static func isAgent(_ command: String,
                               in agents: [AgentDefinition] = AgentDefinition.known) -> Bool {
        agent(forExecutable: command, in: agents) != nil
    }

    /// The known agent an executable belongs to, or nil.
    ///
    /// An agent's `binary` can be a path (`/usr/local/bin/claude`) or bare (`claude`), and
    /// the tty reports a full path — so both sides are reduced to a bare name before
    /// comparing. Without that, an agent configured with an absolute path would never be
    /// recognised while running, which is a silent half-failure: the pane works, and
    /// simply never reports itself as an agent.
    ///
    /// Three spellings of "this file is the agent", because the installers differ:
    /// - the file is named for it: `/opt/homebrew/bin/claude`;
    /// - the file is the agent's name with a platform suffix: npm's Codex runs
    ///   `codex-aarch64-apple-darwin`;
    /// - the file is a VERSION, in a folder named for the agent: Claude Code's native
    ///   install runs `~/.local/share/claude/versions/2.1.311`. Only a version-looking
    ///   name is matched by its folders, so a user called `claude` running Python from
    ///   their home folder is not an agent.
    public static func agent(forExecutable path: String,
                             in agents: [AgentDefinition] = AgentDefinition.known) -> AgentDefinition? {
        let components = path.split(separator: "/").map(String.init)
        guard let file = components.last, !file.isEmpty else { return nil }
        let folders = components.dropLast()
        return agents.first { agent in
            let name = agent.binaryName
            guard !name.isEmpty else { return false }
            if file == name || file.hasPrefix(name + "-") { return true }
            return isVersionLike(file) && folders.contains(name)
        }
    }

    /// `2.1.311`, `1.0`: digits and dots, starting with a digit.
    static func isVersionLike(_ name: String) -> Bool {
        guard let first = name.first, first.isNumber else { return false }
        return name.allSatisfy { $0.isNumber || $0 == "." }
    }
}
