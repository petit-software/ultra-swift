import Foundation

/// The project's files, as tools a model can call: list a folder, find a file by name,
/// read one, search them all.
///
/// READ-ONLY, and confined to the project root. A chat that can look is useful on its own;
/// a chat that can write needs a diff to approve and an undo, and the agents in the panes
/// beside it already do that job. Listing and searching go by what git would track — the
/// ignored build folders are noise, and an ignored `.env` is not something a model should
/// trip over — but a file named outright can be read whether git ignores it or not.
public struct ProjectFiles: ChatToolbox {
    public let root: URL

    /// A page of `read_file`, in lines, when the model does not say. Enough for most
    /// source files whole; the header tells it how to ask for the rest.
    static let defaultLineCount = 800
    static let maxLineCount = 2_000
    /// The most text one call returns, whatever it is of.
    static let maxCharacters = 60_000
    static let maxEntries = 400
    static let maxMatches = 100
    /// Files bigger than this are not searched: they are data, not source.
    static let maxSearchedBytes = 1_000_000

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public var tools: [ChatTool] {
        [
            ChatTool(name: "list_files",
                     description: "List the files and folders directly inside a folder of the project. Folders end in /.",
                     parameters: [.init("path", .string, "Folder, relative to the project root. Omit for the root.")]),
            ChatTool(name: "find_files",
                     description: "Find files anywhere in the project whose path contains some text. * and ? are wildcards.",
                     parameters: [.init("pattern", .string, "Part of a file name or path, e.g. ChatStore or *.md",
                                        isRequired: true)]),
            ChatTool(name: "read_file",
                     description: "Read a text file of the project. Long files come a page at a time.",
                     parameters: [
                        .init("path", .string, "File, relative to the project root.", isRequired: true),
                        .init("start_line", .integer, "First line to return, from 1. Omit for the top."),
                        .init("line_count", .integer, "How many lines to return. Omit for a page of \(Self.defaultLineCount)."),
                     ]),
            ChatTool(name: "search_files",
                     description: "Search the text of the project's files, ignoring case. Returns path:line: text.",
                     parameters: [
                        .init("query", .string, "The text to look for.", isRequired: true),
                        .init("path", .string, "Only search inside this folder. Omit for the whole project."),
                     ]),
        ]
    }

    public func run(_ call: ChatToolCall) async -> String {
        let text: String
        switch call.name {
        case "list_files": text = list(call.string("path") ?? "")
        case "find_files": text = find(call.string("pattern") ?? "")
        case "read_file":
            text = read(call.string("path") ?? "", startLine: call.integer("start_line"),
                        lineCount: call.integer("line_count"))
        case "search_files": text = search(call.string("query") ?? "", under: call.string("path") ?? "")
        default: text = "Error: there is no tool called \(call.name)."
        }
        guard text.count > Self.maxCharacters else { return text }
        return String(text.prefix(Self.maxCharacters)) + "\n… cut off at \(Self.maxCharacters) characters. Ask for less at a time."
    }

    /// What a call is, in a few words, for the row the pane shows: "Read Package.swift".
    public static func summary(of call: ChatToolCall) -> String {
        switch call.name {
        case "list_files":
            let path = call.string("path") ?? ""
            return "List \(path.isEmpty || path == "." ? "the project" : path)"
        case "find_files": return "Find \(call.string("pattern") ?? "")"
        case "read_file":
            guard let start = call.integer("start_line"), start > 1 else {
                return "Read \(call.string("path") ?? "")"
            }
            return "Read \(call.string("path") ?? "") from line \(start)"
        case "search_files": return "Search for “\(call.string("query") ?? "")”"
        default: return call.name
        }
    }

    // MARK: - Tools

    func list(_ path: String) -> String {
        guard let folder = resolve(path) else { return Self.outside(path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "Error: \(path) is not a folder of the project."
        }
        let prefix = relativePath(of: folder).map { $0.isEmpty ? "" : $0 + "/" } ?? ""
        // The first path component under the folder, for every file below it: folders
        // fall out of the file list rather than being asked for one at a time.
        var seen = Set<String>()
        var entries: [String] = []
        for file in files() where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count)
            let entry = rest.firstIndex(of: "/").map { String(rest[...$0]) } ?? String(rest)
            if seen.insert(entry).inserted { entries.append(entry) }
        }
        guard !entries.isEmpty else { return "Nothing here that git would track." }
        entries.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Self.capped(entries, noun: "entries")
    }

    func find(_ pattern: String) -> String {
        guard !pattern.isEmpty else { return "Error: pattern is required." }
        let wild = pattern.contains("*") || pattern.contains("?")
        let predicate = NSPredicate(format: "SELF LIKE[c] %@", "*\(pattern)*")
        let matches = files().filter { file in
            wild ? predicate.evaluate(with: file) : file.localizedCaseInsensitiveContains(pattern)
        }
        guard !matches.isEmpty else { return "No file's path matches \(pattern)." }
        return Self.capped(matches, noun: "files")
    }

    func read(_ path: String, startLine: Int?, lineCount: Int?) -> String {
        guard !path.isEmpty else { return "Error: path is required." }
        guard let file = resolve(path) else { return Self.outside(path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            return "Error: there is no file at \(path). find_files can look for it by name."
        }
        guard !isDirectory.boolValue else { return "Error: \(path) is a folder. Use list_files." }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return "Error: \(path) could not be read."
        }
        guard !Self.looksBinary(data) else { return "\(path) is not text (\(data.count) bytes)." }

        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let start = max(1, startLine ?? 1)
        guard start <= lines.count else {
            return "Error: \(path) has \(lines.count) lines; line \(start) is past the end."
        }
        let count = min(max(1, lineCount ?? Self.defaultLineCount), Self.maxLineCount)
        let end = min(lines.count, start + count - 1)
        var header = "\(path) — lines \(start)–\(end) of \(lines.count)"
        if end < lines.count { header += ". For more, call again with start_line \(end + 1)" }
        return header + "\n\n" + lines[(start - 1)..<end].joined(separator: "\n")
    }

    func search(_ query: String, under path: String) -> String {
        guard !query.isEmpty else { return "Error: query is required." }
        guard let folder = resolve(path), let relative = relativePath(of: folder) else {
            return Self.outside(path)
        }
        let prefix = relative.isEmpty ? "" : relative + "/"
        var matches: [String] = []
        search: for file in files() where file.hasPrefix(prefix) {
            if Task.isCancelled { break }
            let url = root.appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maxSearchedBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !Self.looksBinary(data) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard text.localizedCaseInsensitiveContains(query) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.localizedCaseInsensitiveContains(query) {
                let shown = line.trimmingCharacters(in: .whitespaces)
                matches.append("\(file):\(index + 1): \(shown.count > 200 ? String(shown.prefix(200)) + "…" : shown)")
                if matches.count > Self.maxMatches { break search }
            }
        }
        guard !matches.isEmpty else { return "Nothing matches “\(query)”." }
        return Self.capped(matches, limit: Self.maxMatches, noun: "matches")
    }

    // MARK: - The file list

    /// Every file of the project, as paths relative to the root, sorted. What git tracks
    /// or would — so the ignore rules are git's own — and, outside a repository, a walk of
    /// the folder that skips hidden files and the folders nobody wants listed.
    func files() -> [String] {
        gitFiles() ?? walkedFiles()
    }

    private func gitFiles() -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "ls-files", "-z",
                             "--cached", "--others", "--exclude-standard"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read to the end BEFORE waiting: a list longer than the pipe's buffer would
        // otherwise block git on a write nobody is reading.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let files = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        // A file deleted but not yet committed is still in the index.
        return files.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            .sorted()
    }

    static let skippedFolders: Set<String> = ["node_modules", "DerivedData", "build", "dist", "Pods"]

    private func walkedFiles() -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if Self.skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
            } else if let path = relativePath(of: url) {
                files.append(path)
            }
            if files.count >= 50_000 { break }
        }
        return files.sorted()
    }

    // MARK: - Paths

    /// A path the model gave, as a URL inside the root — or nil if it leads out of it,
    /// by `..` or by a symlink. Absolute paths are taken if they are inside.
    func resolve(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : root.appendingPathComponent(trimmed.isEmpty ? "." : trimmed)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return relativePath(of: resolved) == nil ? nil : resolved
    }

    /// Relative to the root: empty for the root itself, nil for anything outside it.
    private func relativePath(of url: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == root.path { return "" }
        guard path.hasPrefix(root.path + "/") else { return nil }
        return String(path.dropFirst(root.path.count + 1))
    }

    private static func outside(_ path: String) -> String {
        "Error: \(path) is outside the project. Paths are relative to the project root."
    }

    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0)
    }

    private static func capped(_ lines: [String], limit: Int = maxEntries, noun: String) -> String {
        guard lines.count > limit else { return lines.joined(separator: "\n") }
        return lines.prefix(limit).joined(separator: "\n")
            + "\n… more than \(limit) \(noun). Narrow it down."
    }
}
