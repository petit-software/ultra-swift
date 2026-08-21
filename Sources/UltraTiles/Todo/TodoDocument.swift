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

    public mutating func removeItem(_ id: Int) {
        guard lines.indices.contains(id), Self.parseTask(lines[id].content) != nil else { return }
        lines.remove(at: id)
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
