import Testing
import Foundation
@testable import UltraCore

/// The project's agent list, `.ultra/agents.json`.
///
/// Two properties under test: a project with no file behaves exactly as it did before the
/// file existed, and a project that has one is never given the defaults back over its own
/// answer — not by a second install, not by an unreadable file, not by an emptied list.
@Suite("Project agents")
struct ProjectAgentsTests {

    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-project-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a project with no file reads as the built-in defaults, and gets no file for it")
    func defaultsWhenAbsent() throws {
        let root = try sandbox()
        #expect(ProjectAgents.load(in: root) == AgentDefinition.builtIns)
        #expect(!ProjectAgents.exists(in: root), "reading must not write")
    }

    @Test("the defaults are the three CLIs a new project is expected to use")
    func defaultsAreTheKnownAgents() {
        #expect(AgentDefinition.builtIns.map(\.binary) == ["claude", "codex", "gemini"])
    }

    @Test("a saved list comes back in order, creating .ultra on the way")
    func roundTrip() throws {
        let root = try sandbox()
        let agents = [AgentDefinition(name: "Opus", command: "claude --model opus"),
                      AgentDefinition(name: "Local", command: "/opt/bin/agent --resume")]
        try ProjectAgents.save(agents, in: root)
        #expect(ProjectAgents.exists(in: root))
        #expect(ProjectAgents.load(in: root) == agents)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".ultra").path))
    }

    @Test("install writes the defaults once and never over an edited list")
    func installIsOneShot() throws {
        let root = try sandbox()
        #expect(try ProjectAgents.install(in: root))
        #expect(ProjectAgents.load(in: root) == AgentDefinition.builtIns)

        let edited = [AgentDefinition(name: "Only", command: "only")]
        try ProjectAgents.save(edited, in: root)
        #expect(try ProjectAgents.install(in: root) == false)
        #expect(ProjectAgents.load(in: root) == edited)
    }

    /// The user removed every agent. That is an answer, and the next open must not put
    /// the defaults back — an empty list on disk is not the same as no list.
    @Test("an emptied list stays empty")
    func emptyListIsKept() throws {
        let root = try sandbox()
        try ProjectAgents.save([], in: root)
        #expect(ProjectAgents.load(in: root).isEmpty)
        #expect(ProjectAgents.exists(in: root))
    }

    @Test("an unreadable file reads as the defaults and is left where it is")
    func corruptFileIsLeftAlone() throws {
        let root = try sandbox()
        let url = ProjectAgents.url(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(ProjectAgents.load(in: root) == AgentDefinition.builtIns)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json",
                "a file in someone's repository is not this app's to rewrite")
    }

    /// Committed files get diffed. A key order that depends on the encoder's mood would
    /// make every save a whole-file change.
    @Test("the file is stable, versioned, and readable by a person")
    func fileShape() throws {
        let root = try sandbox()
        try ProjectAgents.save([AgentDefinition(name: "A", command: "a")], in: root)
        let text = try String(contentsOf: ProjectAgents.url(in: root), encoding: .utf8)
        #expect(text.contains("\"version\" : 1"))
        #expect(text.contains("\n"), "pretty printed")
        let first = text.firstRange(of: "\"agents\"")!.lowerBound
        let second = text.firstRange(of: "\"version\"")!.lowerBound
        #expect(first < second, "keys sorted, so a diff shows the change and nothing else")
    }

    @Test("cleaning drops rows that cannot be launched and trims the rest")
    func cleaning() {
        let cleaned = ProjectAgents.cleaned([
            AgentDefinition(name: "  Claude ", command: " claude "),
            AgentDefinition(name: "No command", command: "   "),
            AgentDefinition(name: "", command: "orphan"),
        ])
        #expect(cleaned == [AgentDefinition(name: "Claude", command: "claude")])
    }
}
