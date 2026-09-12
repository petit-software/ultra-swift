import Foundation

/// The `AGENTS.md` Ultra writes into a project: how an agent in a pane should use the files
/// the other panes keep.
///
/// Every tile's justification for being a FILE — "the agent in the next pane can read and
/// update it with no integration work" — assumes the agent knows the file is there and what
/// the rules are. It does not, unless told. `AGENTS.md` is where agent CLIs are told things,
/// so this is the telling: plan in the todo list, treat `@path` as a reference, leave the
/// bookmarks and chats alone, work in the current worktree.
///
/// Three rules keep this from being the kind of generated file people learn to hate:
///
/// 1. **Ultra owns only what sits between its markers.** The section is replaced in place on
///    a later run; everything the user wrote around it is untouched, byte for byte.
/// 2. **It is written when a project is CREATED, and on request.** Opening some folder in
///    Ultra does not drop a file into it. A section already there is refreshed on open, since
///    the project has opted in — that is how a project keeps up with new versions of the text.
/// 3. **It is short.** An agent reads this on every prompt. The deep explanations live in
///    Ultra's own docs, not in every repository.
///
/// Pure and headless, like `NewProject`: paths in, files on disk out, nothing to click.
public enum AgentInstructions {

    public static let fileName = "AGENTS.md"
    public static let startMarker = "<!-- ultra:start -->"
    public static let endMarker = "<!-- ultra:end -->"

    /// Where the project keeps the files the section talks about, relative to its root.
    ///
    /// The todo path is a parameter because it is the one a project chooses for itself —
    /// `TodoStore` adopts an existing `TODO.md` and remembers a relocation. The other two are
    /// fixed by the tiles that write them.
    public struct Paths: Equatable, Sendable {
        public var todo: String
        public var context: String
        public var chats: String

        public init(todo: String = ".ultra/todo.md",
                    context: String = ".ultra/context.json",
                    chats: String = ".ultra/chats/") {
            self.todo = todo
            self.context = context
            self.chats = chats
        }
    }

    /// What `write` did, so the caller can say so.
    public enum Outcome: Equatable, Sendable {
        case created
        case updated
        case unchanged
    }

    // MARK: - The text

    /// The Ultra section, markers included.
    ///
    /// Forty-odd lines on purpose. Every one of them is paid for in tokens on every turn of
    /// every agent in every project, so each earns its place by changing what the agent does.
    public static func section(paths: Paths = Paths()) -> String {
        """
        \(startMarker)
        ## Working in Ultra

        You are running in a pane of Ultra, a Mac terminal. The panes beside you show
        project files you can read and edit directly.

        ### Plan in the todo list
        - The plan lives in `\(paths.todo)` — a GitHub task list. `##` headings are
          sections; nested items are subtasks.
        - Read it before starting. Add tasks before the work, check them off as each finishes.
        - Edit only task lines, with small targeted edits. Keep prose, notes and blank lines
          exactly as they are; the file is round-tripped losslessly and watched live.
        - The user edits the same file as you work and may send a task line to you as a prompt.

        ### Context references
        - `@path` in a prompt points at a file or folder the user dropped into the Context
          pane. Read it; it is a reference, not a command.
        - Do not edit `\(paths.context)` by hand. It holds bookmarks, not content.

        ### Chats
        - `\(paths.chats)` holds the user's conversations with a model in a Chat pane.
          Read them for earlier decisions if useful. Never modify or delete them.

        ### Git, servers, processes
        - Work in the current worktree. Do not switch branches, stash, or reset under the
          user. Commit only when asked.
        - Start dev servers in the foreground of this shell rather than daemonising them,
          so they show up in the Ports pane with this pane as their owner.

        ### Committed and local
        - `\(paths.todo)` is committed: it is the project's plan.
        - `\(paths.context)` and `\(paths.chats)` are ignored: bookmarks are per machine
          and chats are personal.
        \(endMarker)
        """
    }

    /// The file's text after the section has been put in.
    ///
    /// Three cases, and the third is the one that matters: an `AGENTS.md` that already has
    /// the markers gets only the part between them replaced. A user's build instructions,
    /// conventions and hard-won warnings above and below it are the reason the file exists,
    /// and a generator that rewrote them would be uninstalled by lunchtime.
    public static func merged(into existing: String?, section: String) -> String {
        guard let existing, !existing.isEmpty else {
            // A new file gets a heading with the project's name to be filled in, and a slot
            // for the notes every project ends up needing — the section says nothing about
            // building or testing THIS project, and that is the first thing an agent asks.
            return section + "\n\n## Project notes\n\n<!-- build, test and run commands; conventions -->\n"
        }
        if let start = existing.range(of: startMarker),
           let end = existing.range(of: endMarker, range: start.upperBound..<existing.endIndex) {
            return existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: section)
        }
        // No markers: append, separated by one blank line from whatever was last.
        let trimmed = existing.hasSuffix("\n") ? existing : existing + "\n"
        return trimmed + "\n" + section + "\n"
    }

    // MARK: - Writing

    /// Put the section into `<root>/AGENTS.md`, creating the file if it is not there.
    ///
    /// Unchanged text is not rewritten: the mtime is what an editor and a file watcher go
    /// by, and touching a file nothing changed in is how a project ends up "modified" in
    /// every tool for no reason.
    @discardableResult
    public static func write(in root: URL,
                             paths: Paths = Paths(),
                             fileManager: FileManager = .default) throws -> Outcome {
        let url = root.appendingPathComponent(fileName)
        let existing = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        let text = merged(into: existing, section: section(paths: paths))
        if text == existing { return .unchanged }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return existing == nil ? .created : .updated
    }

    /// Bring an existing section up to date, and do nothing at all to a project without one.
    ///
    /// This is what runs when a project is OPENED. A section is a project's opt-in; its
    /// absence is not an invitation.
    @discardableResult
    public static func refresh(in root: URL,
                               paths: Paths = Paths(),
                               fileManager: FileManager = .default) throws -> Outcome {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let existing = String(data: data, encoding: .utf8),
              existing.contains(startMarker), existing.contains(endMarker) else {
            return .unchanged
        }
        return try write(in: root, paths: paths, fileManager: fileManager)
    }

    // MARK: - The files around it

    /// The lines `.gitignore` needs so the per-machine and personal files stay out of the
    /// repository. The todo list is deliberately NOT here — it is the plan, and it is tracked.
    public static func ignoreLines(paths: Paths = Paths()) -> [String] {
        [paths.chats, paths.context]
    }

    /// Add the ignore lines a repository is missing. Not a repository: nothing happens, since
    /// a `.gitignore` in a plain folder is noise.
    ///
    /// Matched line by line so a project that already ignores `.ultra/` wholesale, or lists
    /// one of the two under a different comment, is left exactly as it is.
    @discardableResult
    public static func ensureIgnored(in root: URL,
                                     paths: Paths = Paths(),
                                     fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return false
        }
        let url = root.appendingPathComponent(".gitignore")
        let existing = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let present = Set(existing.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        let missing = ignoreLines(paths: paths).filter { line in
            !present.contains(line)
                && !present.contains(line.hasSuffix("/") ? String(line.dropLast()) : line + "/")
                && !present.contains(".ultra") && !present.contains(".ultra/")
        }
        guard !missing.isEmpty else { return false }

        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += "# Ultra: per-machine bookmarks and personal chat transcripts. The todo list beside\n"
        text += "# them is the plan and stays tracked.\n"
        text += missing.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Claude Code reads `CLAUDE.md`, not `AGENTS.md`. A one-line `CLAUDE.md` importing the
    /// other is how the two are kept from drifting into two documents. Only written when
    /// there is no `CLAUDE.md` at all: one that exists is the user's, whatever it says.
    @discardableResult
    public static func linkClaude(in root: URL,
                                  fileManager: FileManager = .default) throws -> Bool {
        let url = root.appendingPathComponent("CLAUDE.md")
        guard !fileManager.fileExists(atPath: url.path) else { return false }
        try "@AGENTS.md\n".write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Everything a new project gets: the section, the ignore lines, the Claude link.
    @discardableResult
    public static func install(in root: URL,
                               paths: Paths = Paths(),
                               fileManager: FileManager = .default) throws -> Outcome {
        let outcome = try write(in: root, paths: paths, fileManager: fileManager)
        try ensureIgnored(in: root, paths: paths, fileManager: fileManager)
        try linkClaude(in: root, fileManager: fileManager)
        return outcome
    }

    // MARK: - Paths

    /// A file's path as the section should print it: relative to the project when it is
    /// inside, absolute when the user has put the list somewhere else entirely.
    public static func displayPath(_ url: URL, relativeTo root: URL) -> String {
        let file = url.standardizedFileURL.path
        var base = root.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        return file.hasPrefix(base) ? String(file.dropFirst(base.count)) : file
    }
}
