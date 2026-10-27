import Foundation

/// The slash commands an agent answers to, for the `/` picker at its prompt.
///
/// Two sources, joined: a built-in list per agent, which is the part of the agent's own
/// `/help` worth having at the keyboard, and the commands a project or a user has added
/// as files — Claude Code's `.claude/commands/*.md` and `.claude/skills/*/SKILL.md`,
/// Codex's `~/.codex/prompts/*.md`. The files are what make this worth more than a typed
/// `/`: a project's own commands are the ones nobody remembers the names of.
///
/// Pure and headless, like `ProjectAgents`: an agent name and a root in, a list out.
public enum AgentCommands {

    public struct Command: Equatable, Sendable, Identifiable {
        public var id: String { name }
        /// Without the slash: `compact`, `review`, `frontend:component`.
        public var name: String
        /// One line, from the agent's documentation or the file's `description:`.
        public var detail: String?
        /// Where it came from, for the row's glyph: the agent, the project, or the user.
        public var origin: Origin

        public init(name: String, detail: String? = nil, origin: Origin) {
            self.name = name
            self.detail = detail
            self.origin = origin
        }
    }

    public enum Origin: Equatable, Sendable {
        case builtIn, project, user
    }

    /// Every command for this agent, built-ins first, then the project's, then the user's,
    /// each group in name order, and no name twice: a project command shadows a built-in
    /// of the same name, as it does in the agent.
    public static func commands(for agent: String, in root: URL?,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Command] {
        let binary = (agent as NSString).lastPathComponent
        let project = root.map { custom(for: binary, in: $0, origin: .project) } ?? []
        let user = custom(for: binary, in: home, origin: .user)
        // The files win: a project's `/review` is the one the agent runs, so it is the
        // one the picker shows. Among the files the project's wins over the user's.
        let shadowed = Set(project.map(\.name) + user.map(\.name))
        var seen = Set<String>()
        var result: [Command] = []
        let groups: [[Command]] = [
            builtIn(for: binary).filter { !shadowed.contains($0.name) },
            project,
            user,
        ]
        for group in groups {
            for command in group.sorted(by: { $0.name < $1.name }) where seen.insert(command.name).inserted {
                result.append(command)
            }
        }
        return result
    }

    // MARK: Built in

    /// The agent's own commands. A table rather than a probe: no agent prints its list in
    /// a form a program can read, and the ones here are the ones that stay from release
    /// to release. Unknown agent, empty list — the picker still shows the custom ones.
    public static func builtIn(for binary: String) -> [Command] {
        let table: [(String, String)]
        switch binary {
        case "claude":
            table = [
                ("help", "Show commands and usage"),
                ("clear", "Clear the conversation"),
                ("compact", "Summarise the conversation to free context"),
                ("context", "Show what is using the context window"),
                ("cost", "Show token usage and cost"),
                ("model", "Choose the model"),
                ("plan", "Switch to plan mode"),
                ("review", "Review a pull request"),
                ("resume", "Resume an earlier conversation"),
                ("rewind", "Go back to an earlier point"),
                ("memory", "Edit the CLAUDE.md memory files"),
                ("init", "Write a CLAUDE.md for this project"),
                ("config", "Open the settings"),
                ("permissions", "Manage what the agent may do"),
                ("hooks", "Manage hooks"),
                ("agents", "Manage subagents"),
                ("mcp", "Manage MCP servers"),
                ("add-dir", "Add a working directory"),
                ("ide", "Connect to an IDE"),
                ("status", "Show version, model and account"),
                ("doctor", "Check the installation"),
                ("usage", "Show plan usage limits"),
                ("statusline", "Set up the status line"),
                ("terminal-setup", "Set up the terminal's keys"),
                ("vim", "Toggle vim editing"),
                ("export", "Export the conversation"),
                ("pr-comments", "Show a pull request's comments"),
                ("release-notes", "Show the release notes"),
                ("bug", "Report a bug"),
                ("login", "Sign in"),
                ("logout", "Sign out"),
                ("exit", "Quit"),
            ]
        case "codex":
            table = [
                ("model", "Choose the model and reasoning effort"),
                ("approvals", "Choose what the agent may do without asking"),
                ("review", "Review the working tree"),
                ("new", "Start a new conversation"),
                ("init", "Write an AGENTS.md for this project"),
                ("compact", "Summarise the conversation to free context"),
                ("diff", "Show the changes so far"),
                ("mention", "Mention a file"),
                ("status", "Show session, model and usage"),
                ("mcp", "List MCP servers"),
                ("logout", "Sign out"),
                ("quit", "Quit"),
            ]
        case "gemini":
            table = [
                ("help", "Show commands and usage"),
                ("clear", "Clear the screen"),
                ("compress", "Summarise the conversation to free context"),
                ("chat", "Save, resume or list conversations"),
                ("memory", "Show or edit the GEMINI.md memory"),
                ("stats", "Show token usage"),
                ("tools", "List the tools"),
                ("mcp", "List MCP servers"),
                ("editor", "Choose the editor"),
                ("theme", "Choose the theme"),
                ("auth", "Choose how to sign in"),
                ("about", "Show the version"),
                ("bug", "Report a bug"),
                ("quit", "Quit"),
            ]
        default:
            table = []
        }
        return table.map { Command(name: $0.0, detail: $0.1, origin: .builtIn) }
    }

    // MARK: Custom

    /// The commands a folder adds for this agent: for Claude Code its `.claude/commands`
    /// tree, where `frontend/component.md` is `/frontend:component`, and its
    /// `.claude/skills/<name>/SKILL.md`; for Codex its `.codex/prompts/*.md`. A file's
    /// `description:` frontmatter line is the row's detail. Other agents add nothing.
    public static func custom(for binary: String, in folder: URL, origin: Origin) -> [Command] {
        switch binary {
        case "claude":
            let base = folder.appendingPathComponent(".claude", isDirectory: true)
            return markdownCommands(in: base.appendingPathComponent("commands", isDirectory: true),
                                    origin: origin)
                + skills(in: base.appendingPathComponent("skills", isDirectory: true), origin: origin)
        case "codex":
            return markdownCommands(in: folder.appendingPathComponent(".codex/prompts", isDirectory: true),
                                    origin: origin, nested: false)
        default:
            return []
        }
    }

    /// Every `.md` under the folder, named by its path without the extension, with `:`
    /// between the folders — Claude Code's own spelling for a namespaced command.
    static func markdownCommands(in folder: URL, origin: Origin, nested: Bool = true) -> [Command] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: nested ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }
        var result: [Command] = []
        let prefix = folder.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "md" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.path.dropFirst(prefix.count)
            let name = relative.dropLast(3).replacingOccurrences(of: "/", with: ":")
            guard !name.isEmpty else { continue }
            result.append(Command(name: String(name), detail: description(of: url), origin: origin))
        }
        return result
    }

    /// Every `<name>/SKILL.md`, named by its folder.
    static func skills(in folder: URL, origin: Origin) -> [Command] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name in
            let skill = folder.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skill.path) else { return nil }
            return Command(name: name, detail: description(of: skill), origin: origin)
        }
    }

    /// The `description:` line of a file's YAML frontmatter, or nil. Only the head of the
    /// file is read: a command file can be long, and the one line is at the top.
    public static func description(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4096),
              let head = String(data: data, encoding: .utf8) else { return nil }
        var lines = head.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines = lines.dropFirst()
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return nil }
            guard line.hasPrefix("description:") else { continue }
            var value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
