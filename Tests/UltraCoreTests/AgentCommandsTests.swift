import Foundation
import Testing
@testable import UltraCore

/// The `/` picker's list: the agent's own commands and the ones a project adds as files.
@Suite("Agent commands")
struct AgentCommandsTests {

    private func makeProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("each known agent has a built-in list; an unknown one has none")
    func builtIns() {
        #expect(AgentCommands.builtIn(for: "claude").contains { $0.name == "compact" })
        #expect(AgentCommands.builtIn(for: "codex").contains { $0.name == "approvals" })
        #expect(AgentCommands.builtIn(for: "gemini").contains { $0.name == "compress" })
        #expect(AgentCommands.builtIn(for: "zsh").isEmpty)
    }

    @Test("a project's .claude/commands and skills are found, nested names use a colon, and the description is read")
    func projectCommands() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = root.appendingPathComponent(".claude/commands/frontend")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "---\ndescription: \"Make a component\"\n---\nDo it".write(
            to: commands.appendingPathComponent("component.md"), atomically: true, encoding: .utf8)
        try "No frontmatter".write(
            to: root.appendingPathComponent(".claude/commands/ship.md"), atomically: true, encoding: .utf8)
        let skill = root.appendingPathComponent(".claude/skills/review")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: review\ndescription: Review the diff\n---".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let found = AgentCommands.custom(for: "claude", in: root, origin: .project)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(byName["frontend:component"]?.detail == "Make a component")
        #expect(byName["ship"] != nil)
        #expect(byName["ship"]?.detail == nil)
        #expect(byName["review"]?.detail == "Review the diff")
        #expect(found.allSatisfy { $0.origin == .project })
    }

    @Test("the project's command shadows a built-in of the same name, and the list has no duplicates")
    func shadowing() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = root.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "---\ndescription: Ours\n---".write(
            to: commands.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
        // An empty home, so the user's own commands do not leak into the test.
        let home = root.appendingPathComponent("home")
        let all = AgentCommands.commands(for: "/usr/local/bin/claude", in: root, home: home)
        #expect(all.filter { $0.name == "review" }.count == 1)
        #expect(all.first { $0.name == "review" }?.detail == "Ours", "the built-in came first and won")
        #expect(Set(all.map(\.name)).count == all.count)
    }

    @Test("Codex reads .codex/prompts, flat")
    func codexPrompts() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let prompts = root.appendingPathComponent(".codex/prompts/nested")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent(".codex/prompts/deploy.md"), atomically: true, encoding: .utf8)
        try "x".write(to: prompts.appendingPathComponent("deeper.md"), atomically: true, encoding: .utf8)
        let names = AgentCommands.custom(for: "codex", in: root, origin: .user).map(\.name)
        #expect(names == ["deploy"])
    }
}

/// The `@` picker's list: the project's files, shallow first, skipping what nobody mentions.
@Suite("Project file walk")
struct ProjectFilesTests {

    @Test("files are listed by relative path, shallow first, folders with a slash, and build folders skipped")
    func walk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Sources/App", "node_modules/left-pad", ".git"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        for file in ["README.md", "Sources/App/Main.swift", "node_modules/left-pad/index.js", ".git/HEAD"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let paths = ProjectFiles.list(in: root)
        #expect(paths == ["README.md", "Sources/", "Sources/App/", "Sources/App/Main.swift"])
    }

    @Test("the walk stops at the cap")
    func cap() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<20 {
            try "x".write(to: root.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8)
        }
        #expect(ProjectFiles.list(in: root, cap: 5).count == 5)
    }
}
