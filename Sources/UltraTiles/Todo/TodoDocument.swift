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
        parseHeadingLine(line)?.title
    }

    /// The title and the number of `#` in front of it. The level is what tells a document's
    /// title (`# Plan`) from a section of it (`## Now`).
    static func parseHeadingLine(_ line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix { $0 == "#" }.count
        let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }

    /// What the composer means by a draft that starts with `#`: a section, not a task.
    ///
    /// `nil` for an ordinary draft. An EMPTY title — a bare `#` — is a real answer too: it
    /// is how the composer is pointed back at the top of the list from the keyboard.
    ///
    /// One `#` is written as two. The `#` typed here is a sigil for "section", and sections
    /// are `##` in this format — a single `#` is the document's title, which the list does
    /// not show. Deeper levels are kept as typed.
    public static func sectionDraft(_ draft: String) -> (level: Int, title: String)? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return (max(2, hashes), title)
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

    /// A `#` line. A row of the list in its own right: it can be renamed and removed the
    /// way a task can, so it needs the same handle on its line that a task has.
    public struct Heading: Identifiable, Equatable, Sendable {
        /// The line this heading lives on. Stable for the life of one parse.
        public let id: Int
        public var title: String
        /// How many `#` it is written with.
        public var level: Int
    }

    /// One heading's worth of tasks.
    public struct Group: Identifiable, Equatable, Sendable {
        /// Nil for the run of tasks above any heading.
        public let heading: Heading?
        public var items: [Item]
        public var section: String? { heading?.title }
        /// The heading's line, so two sections with the same title are still two rows.
        public var id: Int { heading?.id ?? -1 }
    }

    /// Tasks grouped by the heading they sit under, in file order.
    ///
    /// The obvious spelling of the "same section as the previous group?" test is
    /// `out.last?.section == item.section`, and it is wrong: `out.last?.section` is a
    /// DOUBLE optional, so on an empty array it flattens to nil and compares equal to a task
    /// that has no section — then the append indexes `out[-1]` and traps. A file whose first
    /// tasks sit above any heading is the common case, not an edge one.
    ///
    /// A heading opens a group whether or not anything is under it yet — a section made
    /// from the composer starts empty, and one that vanished until it had a task in it
    /// would look like a command that did nothing. Two kinds of empty heading are NOT
    /// sections and stay out of the list: a title over subsections (`# Plan` directly above
    /// `## Now`), and a level-one heading opening the file, which names the document.
    public var grouped: [Group] {
        var out: [Group] = []
        for (index, line) in lines.enumerated() {
            if let heading = Self.parseHeadingLine(line.content) {
                out.append(Group(heading: Heading(id: index, title: heading.title,
                                                  level: heading.level), items: []))
            } else if let task = Self.parseTask(line.content) {
                if out.isEmpty { out.append(Group(heading: nil, items: [])) }
                out[out.count - 1].items.append(
                    Item(id: index, isDone: task.done, text: task.text,
                         indent: task.indent, section: out[out.count - 1].section))
            }
        }
        return out.enumerated().compactMap { index, group in
            guard group.items.isEmpty, let heading = group.heading else { return group }
            let next = out.indices.contains(index + 1) ? out[index + 1].heading : nil
            if let next, next.level > heading.level { return nil }
            if index == 0, heading.level == 1 { return nil }
            return group
        }
    }

    /// Whether a group's heading is worth a row.
    ///
    /// A lone level-one heading is the list's title, which the pane header already gives —
    /// so it is just a word in the way. Anything written as a section (`##` and deeper) is
    /// shown even alone: it was put there to be seen, and it is the row it is edited from.
    public func showsHeading(of group: Group) -> Bool {
        guard let heading = group.heading else { return false }
        return heading.level > 1 || grouped.count > 1
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

    // MARK: Sections

    /// Start a section at the END of the list.
    ///
    /// The end, not the top where a new task lands: a heading claims every task below it
    /// up to the next heading, so one inserted above the list would quietly take the whole
    /// list as its own. At the end it starts empty, which is what a new section is.
    ///
    /// A blank line goes above it when the line before is not already one — the shape this
    /// file has when it is written by hand, and what keeps a renderer from reading the
    /// heading as the tail of the last task.
    public mutating func addSection(_ title: String, level: Int = 2) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let ending = Self.dominantTerminator(lines)
        if let last = lines.indices.last {
            if lines[last].terminator.isEmpty { lines[last].terminator = ending }
            if !lines[last].content.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(Line(content: "", terminator: ending))
            }
        }
        lines.append(Line(content: String(repeating: "#", count: max(1, level)) + " " + title,
                          terminator: ending))
    }

    /// Rename a heading. Its `#`s are kept: the level is the file's business, not the row's.
    public mutating func setHeading(_ title: String, for id: Int) {
        guard lines.indices.contains(id),
              let heading = Self.parseHeadingLine(lines[id].content) else { return }
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        lines[id].content = String(repeating: "#", count: heading.level) + " " + title
    }

    /// Take a heading out. ONLY the heading: the tasks under it stay in the file and join
    /// the section above, the way they would if the line were deleted by hand. Removing a
    /// section's name is not a request to delete the work filed under it.
    ///
    /// One of the blank lines that fenced it goes too, when there was one on each side —
    /// otherwise every removed heading leaves a wider gap behind it.
    public mutating func removeHeading(_ id: Int) {
        guard lines.indices.contains(id),
              Self.parseHeadingLine(lines[id].content) != nil else { return }
        func isBlank(_ index: Int) -> Bool {
            lines.indices.contains(index)
                && lines[index].content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let fenced = isBlank(id - 1) && isBlank(id + 1)
        lines.remove(at: id)
        if fenced { lines.remove(at: id) }
    }

    /// Insert a task at the top of one section: above its first task, or directly under the
    /// heading when it has none. Falls back to the top of the list when no heading has that
    /// title — the section was renamed or removed in another editor since it was chosen.
    public mutating func prependItem(_ text: String, to section: String) {
        guard let heading = lines.indices.first(where: {
            Self.parseHeading(lines[$0].content) == section
        }) else {
            prependItem(text)
            return
        }
        var firstTask: Int?
        for index in lines.indices where index > heading {
            if Self.parseHeading(lines[index].content) != nil { break }
            if Self.parseTask(lines[index].content) != nil { firstTask = index; break }
        }
        if let firstTask {
            let indent = Self.parseTask(lines[firstTask].content)?.indent ?? 0
            let content = String(repeating: " ", count: indent) + "- [ ] " + text
            lines.insert(Line(content: content, terminator: lines[firstTask].terminator),
                         at: firstTask)
            return
        }
        // An empty section. The heading may be the file's last line and have no newline of
        // its own; it needs one now, and the new last line inherits the file's ending.
        let fileEnding = lines[heading].terminator
        let ending = fileEnding.isEmpty ? Self.dominantTerminator(lines) : fileEnding
        lines[heading].terminator = ending
        let isLast = heading == lines.count - 1
        lines.insert(Line(content: "- [ ] " + text, terminator: isLast ? fileEnding : ending),
                     at: heading + 1)
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
