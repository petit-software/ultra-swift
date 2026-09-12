import Testing
import Foundation
@testable import UltraCore

/// The `AGENTS.md` Ultra writes into a project, and the two files around it.
///
/// The property under test throughout is restraint: the file says what it must, replaces
/// only what it owns, and leaves a project it was not invited into exactly as it found it.
@Suite("Agent instructions")
struct AgentInstructionsTests {

    private func sandbox(git: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        return url
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - The section

    @Test("the section names the files the tiles keep")
    func sectionNamesTheFiles() {
        let text = AgentInstructions.section(
            paths: .init(todo: "docs/TODO.md", context: ".ultra/context.json", chats: ".ultra/chats/"))
        #expect(text.hasPrefix(AgentInstructions.startMarker))
        #expect(text.hasSuffix(AgentInstructions.endMarker))
        #expect(text.contains("`docs/TODO.md`"))
        #expect(text.contains("`.ultra/context.json`"))
        #expect(text.contains("`.ultra/chats/`"))
    }

    /// An agent reads this on every prompt. Length is a cost, and one that creeps.
    @Test("the section stays short")
    func sectionStaysShort() {
        let lines = AgentInstructions.section().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= 45)
    }

    // MARK: - Merging

    @Test("a new file gets the section and a slot for the project's own notes")
    func newFileHasSectionAndNotes() {
        let text = AgentInstructions.merged(into: nil, section: AgentInstructions.section())
        #expect(text.hasPrefix(AgentInstructions.startMarker))
        #expect(text.contains("## Project notes"))
    }

    @Test("an existing file without markers keeps its text and gains the section at the end")
    func existingFileIsAppended() {
        let mine = "# My project\n\nRun `make test` before every commit."
        let text = AgentInstructions.merged(into: mine, section: "SECTION")
        #expect(text == mine + "\n\nSECTION\n")
    }

    /// The case that decides whether the feature is welcome: the user's own text on both
    /// sides of the section survives a rewrite byte for byte.
    @Test("only the text between the markers is replaced")
    func onlyTheSectionIsReplaced() {
        let before = "# Mine\n\n<!-- ultra:start -->\nold\n<!-- ultra:end -->\n\n## Notes\n\nkeep me\n"
        let text = AgentInstructions.merged(into: before, section: "<!-- ultra:start -->\nnew\n<!-- ultra:end -->")
        #expect(text == "# Mine\n\n<!-- ultra:start -->\nnew\n<!-- ultra:end -->\n\n## Notes\n\nkeep me\n")
    }

    // MARK: - Writing

    @Test("write creates, then reports unchanged, then updates when the section moves on")
    func writeReportsWhatItDid() throws {
        let root = try sandbox()
        #expect(try AgentInstructions.write(in: root) == .created)
        #expect(try AgentInstructions.write(in: root) == .unchanged)
        #expect(try AgentInstructions.write(in: root, paths: .init(todo: "TODO.md")) == .updated)
        #expect(read(root.appendingPathComponent("AGENTS.md"))?.contains("`TODO.md`") == true)
    }

    @Test("write leaves the user's notes around the section alone")
    func writeKeepsNotes() throws {
        let root = try sandbox()
        try AgentInstructions.write(in: root)
        let url = root.appendingPathComponent("AGENTS.md")
        let annotated = read(url)! + "\nAlways run swift test.\n"
        try annotated.write(to: url, atomically: true, encoding: .utf8)

        try AgentInstructions.write(in: root, paths: .init(todo: "TODO.md"))
        let after = read(url)!
        #expect(after.hasSuffix("\nAlways run swift test.\n"))
        #expect(after.contains("`TODO.md`"))
        #expect(!after.contains("`.ultra/todo.md`"))
    }

    // MARK: - Refreshing on open

    @Test("refresh does nothing to a project that has no section")
    func refreshIsNotAnInvitation() throws {
        let root = try sandbox()
        #expect(try AgentInstructions.refresh(in: root) == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))

        let url = root.appendingPathComponent("AGENTS.md")
        try "# Mine\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try AgentInstructions.refresh(in: root) == .unchanged)
        #expect(read(url) == "# Mine\n")
    }

    @Test("refresh brings an existing section up to date")
    func refreshUpdatesASection() throws {
        let root = try sandbox()
        let url = root.appendingPathComponent("AGENTS.md")
        try "<!-- ultra:start -->\nstale\n<!-- ultra:end -->\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try AgentInstructions.refresh(in: root) == .updated)
        #expect(read(url)?.contains("stale") == false)
        #expect(read(url)?.contains("## Working in Ultra") == true)
    }

    // MARK: - .gitignore

    @Test("a repository gains the two ignore lines, and the todo list is not one of them")
    func ignoreLinesAreAdded() throws {
        let root = try sandbox(git: true)
        #expect(try AgentInstructions.ensureIgnored(in: root))
        let text = read(root.appendingPathComponent(".gitignore"))!
        #expect(text.contains(".ultra/chats/\n"))
        #expect(text.contains(".ultra/context.json\n"))
        #expect(!text.contains("todo.md"))
        // Idempotent.
        #expect(try !AgentInstructions.ensureIgnored(in: root))
    }

    @Test("a plain folder gets no .gitignore")
    func plainFolderIsNotIgnored() throws {
        let root = try sandbox(git: false)
        #expect(try !AgentInstructions.ensureIgnored(in: root))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    }

    @Test("a .gitignore that already covers the files is left alone", arguments: [
        ".ultra/\n",
        ".ultra\n",
        "build/\n.ultra/chats\n.ultra/context.json\n",
        "  .ultra/chats/  \n.ultra/context.json\n",
    ])
    func coveredIgnoreIsUntouched(existing: String) throws {
        let root = try sandbox(git: true)
        let url = root.appendingPathComponent(".gitignore")
        try existing.write(to: url, atomically: true, encoding: .utf8)
        #expect(try !AgentInstructions.ensureIgnored(in: root))
        #expect(read(url) == existing)
    }

    @Test("an existing .gitignore is appended to, not rewritten")
    func existingIgnoreIsAppended() throws {
        let root = try sandbox(git: true)
        let url = root.appendingPathComponent(".gitignore")
        try "build/".write(to: url, atomically: true, encoding: .utf8)
        try AgentInstructions.ensureIgnored(in: root)
        let text = read(url)!
        #expect(text.hasPrefix("build/\n\n# Ultra"))
        #expect(text.hasSuffix(".ultra/chats/\n.ultra/context.json\n"))
    }

    // MARK: - CLAUDE.md

    @Test("CLAUDE.md imports AGENTS.md, and only when there was none")
    func claudeLink() throws {
        let root = try sandbox()
        let url = root.appendingPathComponent("CLAUDE.md")
        #expect(try AgentInstructions.linkClaude(in: root))
        #expect(read(url) == "@AGENTS.md\n")

        try "my own\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try !AgentInstructions.linkClaude(in: root))
        #expect(read(url) == "my own\n")
    }

    // MARK: - Paths

    @Test("a todo file inside the project is shown relative, one outside is shown absolute")
    func displayPaths() throws {
        let root = try sandbox()
        #expect(AgentInstructions.displayPath(root.appendingPathComponent("docs/TODO.md"), relativeTo: root)
                == "docs/TODO.md")
        let elsewhere = URL(fileURLWithPath: "/Users/someone/notes/todo.md")
        #expect(AgentInstructions.displayPath(elsewhere, relativeTo: root) == "/Users/someone/notes/todo.md")
        // A sibling whose name merely starts with the root's is not inside it.
        let sibling = URL(fileURLWithPath: root.path + "-other/todo.md")
        #expect(AgentInstructions.displayPath(sibling, relativeTo: root) == sibling.path)
    }
}
