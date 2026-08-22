import Foundation

/// A markdown todo list that keeps every byte it does not own.
///
/// The model is the FILE — an array of lines with their original terminators — not a list of
/// tasks. Tasks are views onto line indices. Toggling rewrites the single character inside
/// one line's checkbox and touches nothing else, so "round-trip is lossless" is true by
/// construction rather than by careful re-serialisation. Prose, front matter, code fences,
/// indentation and blank lines survive because they are never parsed in the first place.
///
/// See docs/03-TILES.md § 2.
public struct TodoDocument: Equatable, Sendable {

    /// One line, split from its terminator so a file with CRLF, or with no trailing
    /// newline, comes back exactly as it went in.
    struct Line: Equatable, Sendable {
        var content: String
        var terminator: String
    }

    public struct Item: Identifiable, Equatable, Sendable {
        /// The line this task lives on. Stable for the life of one parse.
        public let id: Int
        public var isDone: Bool
        public var text: String
        /// Leading whitespace width, in columns — nesting depth as the file expresses it.
        public var indent: Int
        /// The nearest `#` heading above this task, if any.
        public var section: String?
    }

    private var lines: [Line]

    public init(text: String) {
        lines = Self.split(text)
    }

    // MARK: Text

    /// Exactly the bytes this document represents.
    public var text: String {
        lines.map { $0.content + $0.terminator }.joined()
    }

    /// Split preserving terminators.
    ///
    /// Iterating `Character`s is what makes this correct: Swift treats CRLF as ONE grapheme
    /// cluster, so a byte-wise scan comparing against "\r" and "\n" separately never matches
    /// a CRLF file and silently collapses it into a single line. Round-tripping still passes
    /// when that happens, which is exactly how the bug hides — the parse is what breaks.
    private static func split(_ text: String) -> [Line] {
        var out: [Line] = []
        var content = ""
        for character in text {
            if character == "\r\n" || character == "\n" || character == "\r" {
                out.append(Line(content: content, terminator: String(character)))
                content = ""
            } else {
                content.append(character)
            }
        }
        // A file not ending in a newline keeps a final line with no terminator, so it comes
        // back without one too.
        if !content.isEmpty { out.append(Line(content: content, terminator: "")) }
        return out
    }

    // MARK: Parsing

    /// `- [ ] text`, `* [x] text`, `+ [X] text`, at any indentation.
    /// Returns the range of the checkbox character so a toggle can rewrite just that byte.
    static func parseTask(_ line: String) -> (indent: Int, done: Bool, text: String,
                                              markIndex: String.Index)? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, "-*+".contains(line[index]) else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == " " else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == "[" else { return nil }
        let mark = line.index(after: index)
        guard mark < line.endIndex else { return nil }
        let close = line.index(after: mark)
        guard close < line.endIndex, line[close] == "]" else { return nil }
        let done: Bool
        switch line[mark] {
        case " ": done = false
        case "x", "X": done = true
        default: return nil
        }
        var textStart = line.index(after: close)
        if textStart < line.endIndex, line[textStart] == " " {
            textStart = line.index(after: textStart)
        }
        return (indent, done, String(line[textStart...]), mark)
    }

    static func parseHeading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// Every task in the file, in file order.
    public var items: [Item] {
        var out: [Item] = []
        var section: String?
        for (index, line) in lines.enumerated() {
            if let heading = Self.parseHeading(line.content) {
                section = heading
                continue
            }
            guard let task = Self.parseTask(line.content) else { continue }
            out.append(Item(id: index, isDone: task.done, text: task.text,
                            indent: task.indent, section: section))
        }
        return out
    }

    /// One heading's worth of tasks.
    public struct Group: Identifiable, Equatable, Sendable {
        public let section: String?
        public var items: [Item]
        /// Stable across reloads; the empty string is the run of tasks above any heading.
        public var id: String { section ?? "" }
    }

    /// Tasks grouped by the heading they sit under, in file order.
    ///
    /// The obvious spelling of the "same section as the previous group?" test is
    /// `out.last?.section == item.section`, and it is wrong: `out.last?.section` is a
    /// DOUBLE optional, so on an empty array it flattens to nil and compares equal to a task
    /// that has no section — then the append indexes `out[-1]` and traps. A file whose first
    /// tasks sit above any heading is the common case, not an edge one.
    public var grouped: [Group] {
        var out: [Group] = []
        for item in items {
            if let last = out.last, last.section == item.section {
                out[out.count - 1].items.append(item)
            } else {
                out.append(Group(section: item.section, items: [item]))
            }
        }
        return out
    }

    /// Section titles in file order, including a nil entry when tasks precede any heading.
    public var sections: [String] {
        var out: [String] = []
        for line in lines {
            if let heading = Self.parseHeading(line.content), !out.contains(heading) {
                out.append(heading)
            }
        }
        return out
    }

    // MARK: Editing

    /// Flip one checkbox. Rewrites a single character; every other byte in the file is
    /// untouched, including the rest of this very line.
    public mutating func toggle(_ id: Int) {
        guard lines.indices.contains(id),
              let task = Self.parseTask(lines[id].content) else { return }
        var content = lines[id].content
        content.replaceSubrange(task.markIndex...task.markIndex, with: task.done ? " " : "x")
        lines[id].content = content
    }

    public mutating func setText(_ text: String, for id: Int) {
        guard lines.indices.contains(id),
              let task = Self.parseTask(lines[id].content) else { return }
        let prefix = String(lines[id].content[..<task.markIndex])
        lines[id].content = prefix + (task.done ? "x" : " ") + "] " + text
    }

    /// Append a task to the end of a section, or the end of the file when `section` is nil
    /// or absent. Inserted with the same indentation as the last task it joins.
    public mutating func addItem(_ text: String, to section: String? = nil) {
        let insertion = insertionPoint(for: section)
        let indent = indentForInsertion(at: insertion)
        let content = String(repeating: " ", count: indent) + "- [ ] " + text

        guard insertion < lines.count else {
            // Appending at the end. If the file had no trailing newline, the NEW last line
            // inherits that — adding a task must not also add a byte the user did not ask
            // for, or every add shows up in a diff as two changes.
            let style = lines.last?.terminator ?? "\n"
            let ending = style.isEmpty ? "\n" : style
            if let last = lines.indices.last, lines[last].terminator.isEmpty {
                lines[last].terminator = ending
                lines.append(Line(content: content, terminator: ""))
            } else {
                lines.append(Line(content: content, terminator: ending))
            }
            return
        }
        lines.insert(Line(content: content, terminator: lines[insertion].terminator),
                     at: insertion)
    }

    /// Insert a task at the TOP of the list — above every existing task, but BELOW any
    /// heading that opens the file. A task hoisted above its own `# Plan` line would leave
    /// the section, which is not what "add at the top" means to someone looking at the list.
    ///
    /// With no tasks yet this falls through to the ordinary append, so the first task in an
    /// empty file still lands after the headings rather than before them.
    public mutating func prependItem(_ text: String) {
        guard let first = firstTaskIndex() else {
            addItem(text)
            return
        }
        // Match the task BELOW rather than above: the new row joins the head of that list,
        // so it takes that list's indentation.
        let indent = Self.parseTask(lines[first].content)?.indent ?? 0
        let content = String(repeating: " ", count: indent) + "- [ ] " + text
        lines.insert(Line(content: content, terminator: lines[first].terminator), at: first)
    }

    public mutating func removeItem(_ id: Int) {
        guard lines.indices.contains(id), Self.parseTask(lines[id].content) != nil else { return }
        lines.remove(at: id)
    }

    /// Move a task so it sits immediately before `target` — another task's line, or
    /// `lines.count` to put it at the end.
    ///
    /// The line's CONTENT is carried across untouched, indentation included. Adopting the
    /// destination's indent would be a second edit the user did not ask for, and this file
    /// is something they also edit by hand.
    @discardableResult
    public mutating func move(_ id: Int, before target: Int) -> Bool {
        guard lines.indices.contains(id), Self.parseTask(lines[id].content) != nil else { return false }
        guard target >= 0, target <= lines.count else { return false }
        // Dropping a row on itself, or immediately below itself, changes nothing.
        guard target != id, target != id + 1 else { return false }

        // A line whose terminator is EMPTY is the last line of a file that ends without a
        // newline. That property belongs to the END OF THE FILE, not to the line — carrying
        // it into the middle would silently join the moved task to the one after it.
        let fileEnding = lines.last?.terminator ?? "\n"
        var moved = lines.remove(at: id)
        if moved.terminator.isEmpty { moved.terminator = Self.dominantTerminator(lines) }

        let insertion = target > id ? target - 1 : target
        lines.insert(moved, at: min(insertion, lines.count))

        // Whichever line is last now owns the file's ending.
        if let last = lines.indices.last {
            if lines[last].terminator != fileEnding { lines[last].terminator = fileEnding }
            // And no line before it may be left without one.
            for index in lines.indices where index != last && lines[index].terminator.isEmpty {
                lines[index].terminator = Self.dominantTerminator(lines)
            }
        }
        return true
    }

    /// The terminator this file actually uses, so a moved line in a CRLF file stays CRLF.
    private static func dominantTerminator(_ lines: [Line]) -> String {
        lines.first { !$0.terminator.isEmpty }?.terminator ?? "\n"
    }

    /// Where a new task belongs: after the last task of the named section, else end of file.
    private func insertionPoint(for section: String?) -> Int {
        guard let section else {
            return lastTaskIndex().map { $0 + 1 } ?? lines.count
        }
        var inSection = false
        var candidate: Int?
        for (index, line) in lines.enumerated() {
            if let heading = Self.parseHeading(line.content) {
                if inSection { break }
                inSection = (heading == section)
                continue
            }
            if inSection, Self.parseTask(line.content) != nil { candidate = index }
        }
        return candidate.map { $0 + 1 } ?? (lastTaskIndex().map { $0 + 1 } ?? lines.count)
    }

    private func firstTaskIndex() -> Int? {
        lines.indices.first { Self.parseTask(lines[$0].content) != nil }
    }

    private func lastTaskIndex() -> Int? {
        lines.indices.last { Self.parseTask(lines[$0].content) != nil }
    }

    private func indentForInsertion(at index: Int) -> Int {
        // Match the task above, so adding under a nested list stays nested.
        for i in stride(from: min(index, lines.count) - 1, through: 0, by: -1) {
            if let task = Self.parseTask(lines[i].content) { return task.indent }
        }
        return 0
    }
}
