import Foundation

/// An agent CLI the user can launch in a pane.
///
/// Ultra is a harness, not an agent loop: the agent's own interface lives in the terminal,
/// and Ultra provides the project, files, and session around it. See docs/03-TILES.md.
public struct AgentDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// The command line, run through a login shell so it inherits the user's environment.
    public var command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }

    /// Shipped defaults. Users can add their own; nothing here is special-cased.
    public static let builtIns: [AgentDefinition] = [
        AgentDefinition(name: "Claude Code", command: "claude"),
        AgentDefinition(name: "Codex", command: "codex"),
    ]

    /// The binary to probe for availability — the first word of the command line.
    public var binary: String {
        String(command.split(separator: " ").first ?? "")
    }
}

public enum ShellLauncher {

    /// The user's login shell, falling back to zsh (the macOS default since Catalina).
    public static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        let shell = environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    /// Arguments for a plain interactive shell, or for one that immediately becomes an agent.
    ///
    /// `-l -c "exec <command>"` matters in both halves:
    /// - `-l` makes it a LOGIN shell, so the agent inherits the PATH and environment the
    ///   user actually has — a GUI app's environment is not the terminal's.
    /// - `exec` replaces the shell rather than nesting one, so the pane's process *is* the
    ///   agent: signals, exit codes, and the process table all say what the user expects.
    public static func arguments(runningAgent command: String? = nil) -> [String] {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ["-l"]
        }
        return ["-l", "-c", "exec \(command)"]
    }

    /// Whether a binary is on the user's PATH. Probed through a login shell for the same
    /// reason as above: `which` run with the GUI app's PATH gives the wrong answer.
    public static func isAvailable(_ binary: String) -> Bool {
        guard !binary.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell())
        process.arguments = ["-l", "-c", "command -v \(binary)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// A working directory that actually exists. Returns nil rather than silently falling
    /// back to `$HOME` — a pane whose cwd is gone must say so, not open somewhere else.
    public static func validatedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }
}
