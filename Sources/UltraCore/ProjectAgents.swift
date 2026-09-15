import Foundation

/// An agent CLI the user can launch in a pane.
///
/// Ultra is a harness, not an agent loop: the agent's own interface lives in the terminal,
/// and Ultra provides the project, files, and session around it. See docs/03-TILES.md.
///
/// Lives in `UltraCore` rather than beside the shell launcher because a project's list of
/// agents is a FILE — `.ultra/agents.json`, see `ProjectAgents` — and the file layer sits
/// below the terminal layer.
public struct AgentDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// The command line, run through a login shell so it inherits the user's environment.
    public var command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }

    /// Shipped defaults, and what a project gets when it is created. Users edit their own
    /// list per project; nothing here is special-cased.
    public static let builtIns: [AgentDefinition] = [
        AgentDefinition(name: "Claude Code", command: "claude"),
        AgentDefinition(name: "Codex", command: "codex"),
        AgentDefinition(name: "Gemini", command: "gemini"),
    ]

    /// The binary to probe for availability — the first word of the command line.
    public var binary: String {
        String(command.split(separator: " ").first ?? "")
    }
}

/// The agents a project knows about, in `<project>/.ultra/agents.json`.
///
/// A file in the project rather than a preference in `UserDefaults`, for the reason the todo
/// list is a file: it travels with the checkout. A project that runs on `claude --model opus`
/// says so once, in the repository, and every clone opens with the same "New Agent Pane"
/// menu. It is COMMITTED, like the todo list — the agents are part of how the project is
/// worked on, not a personal bookmark.
///
/// Written when a project is CREATED or CLONED, with the built-in defaults; a project opened
/// without one is read as having the defaults and no file is written until the user edits
/// the list. Opening a folder in Ultra must not drop files into it.
///
/// Pure and headless, like `AgentInstructions`: a root in, a list out.
public enum ProjectAgents {

    public static let relativePath = ".ultra/agents.json"

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// The shape on disk. Versioned so the format can change without a guess at what an
    /// older file meant; a bare array would have no room for that.
    struct File: Codable, Equatable {
        static let currentVersion = 1
        var version: Int
        var agents: [AgentDefinition]
    }

    /// The project's agents, or the defaults when the project has no file.
    ///
    /// An unreadable file is ALSO the defaults, and the file is left alone: the user's own
    /// edit will replace it, and quarantining or deleting a file in someone's repository over
    /// a stray comma is not this app's call. The menu still works either way.
    public static func load(in root: URL, fileManager: FileManager = .default) -> [AgentDefinition] {
        guard let data = fileManager.contents(atPath: url(in: root).path),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return AgentDefinition.builtIns }
        return file.agents
    }

    /// Whether the project has a file of its own, as opposed to being read as the defaults.
    public static func exists(in root: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url(in: root).path)
    }

    /// Write the list. Creates `.ultra/` if the project does not have one yet — a project
    /// created outside Ultra may not — and writes atomically, so a crash mid-write leaves
    /// the old list rather than half of the new one.
    ///
    /// An EMPTY list is written as an empty list, not as "no file". A user who removed every
    /// agent has said something, and the next open must not put the defaults back.
    public static func save(_ agents: [AgentDefinition], in root: URL,
                            fileManager: FileManager = .default) throws {
        let target = url(in: root)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted and pretty: this file is committed, and a diff of it should read as a
        // change to one agent, not as a re-serialisation.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: File.currentVersion, agents: agents))
        try data.write(to: target, options: .atomic)
    }

    /// Give a new project the defaults. Nothing happens to a project that already has a
    /// file — the moment for this is creation, and a second call must not undo an edit.
    @discardableResult
    public static func install(in root: URL, fileManager: FileManager = .default) throws -> Bool {
        guard !exists(in: root, fileManager: fileManager) else { return false }
        try save(AgentDefinition.builtIns, in: root, fileManager: fileManager)
        return true
    }

    /// Whether a list is worth keeping as it is: every agent named, every one with a
    /// command. A row with either blank is a menu item that does nothing, so it is dropped
    /// before the list is written or offered.
    public static func cleaned(_ agents: [AgentDefinition]) -> [AgentDefinition] {
        agents.compactMap { agent in
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = agent.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { return nil }
            return AgentDefinition(name: name, command: command)
        }
    }
}
