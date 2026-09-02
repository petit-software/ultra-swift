import Foundation

/// Which of a file's two diffs is being shown.
///
/// Kept separate on purpose: a file can be staged AND modified at the same time, and one
/// button cannot mean two things. `git diff` is the working tree against the index;
/// `git diff --cached` is the index against HEAD.
public enum DiffSide: String, CaseIterable, Sendable, Identifiable {
    case unstaged, staged
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unstaged: "Working tree"
        case .staged: "Staged"
        }
    }
    /// The argument that selects it. Empty for the working tree, which is git's default.
    public var gitArguments: [String] {
        switch self {
        case .unstaged: []
        case .staged: ["--cached"]
        }
    }
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case context, addition, deletion
        /// `\ No newline at end of file` — git's own marker, not part of the content.
        case marker
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    /// Character ranges within `text` that actually changed, as offsets. Empty when this
    /// line has no counterpart to compare against, or when the two are too different for
    /// intra-line highlighting to mean anything.
    public var emphasis: [Range<Int>] = []
}

public struct DiffHunk: Identifiable, Equatable, Sendable {
    public let id: Int
    /// The text after the `@@ ... @@`, which git fills with the enclosing function.
    public let heading: String
    public let oldStart: Int
    public let newStart: Int
    public var lines: [DiffLine]
}

public struct FileDiff: Equatable, Sendable {
    public let path: String
    public let side: DiffSide
    public let hunks: [DiffHunk]
    public let isBinary: Bool

    public var isEmpty: Bool { hunks.isEmpty && !isBinary }
    public var additions: Int { hunks.flatMap(\.lines).count { $0.kind == .addition } }
    public var deletions: Int { hunks.flatMap(\.lines).count { $0.kind == .deletion } }

    /// The longest line in the diff, in characters.
    ///
    /// A count rather than a measurement, because it is used as one: the rows are monospaced,
    /// so a length times one character's advance IS the width of the widest row — and the
    /// alternative is laying every row out once to ask how wide it came out, then again at
    /// the width that answer implies.
    public var columns: Int { hunks.lazy.flatMap(\.lines).map(\.text.count).max() ?? 0 }

    public static func empty(path: String, side: DiffSide) -> FileDiff {
        FileDiff(path: path, side: side, hunks: [], isBinary: false)
    }
}

/// Parses git's unified diff output.
///
/// Pure, so every shape git can emit — no trailing newline, binary files, renames, an empty
/// diff — is covered without running git.
public enum DiffParser {

    public static func parse(_ raw: String, path: String, side: DiffSide) -> FileDiff {
        guard !raw.isEmpty else { return .empty(path: path, side: side) }
        if raw.contains("\nBinary files ") || raw.hasPrefix("Binary files ") {
            return FileDiff(path: path, side: side, hunks: [], isBinary: true)
        }

        var hunks: [DiffHunk] = []
        var current: DiffHunk?
        var oldLine = 0, newLine = 0
        var lineID = 0

        func closeCurrent() {
            guard var hunk = current else { return }
            hunk.lines = emphasise(hunk.lines)
            hunks.append(hunk)
            current = nil
        }

        for raw in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if line.hasPrefix("@@") {
                closeCurrent()
                guard let header = parseHunkHeader(line) else { continue }
                oldLine = header.oldStart
                newLine = header.newStart
                current = DiffHunk(id: hunks.count, heading: header.heading,
                                   oldStart: header.oldStart, newStart: header.newStart,
                                   lines: [])
                continue
            }

            // Everything before the first @@ is the file header: ---, +++, index, mode.
            guard current != nil else { continue }

            defer { lineID += 1 }
            switch line.first {
            case "+":
                current?.lines.append(DiffLine(id: lineID, kind: .addition,
                                               text: String(line.dropFirst()),
                                               oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                current?.lines.append(DiffLine(id: lineID, kind: .deletion,
                                               text: String(line.dropFirst()),
                                               oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case "\\":
                current?.lines.append(DiffLine(id: lineID, kind: .marker, text: line,
                                               oldNumber: nil, newNumber: nil))
            case " ":
                current?.lines.append(DiffLine(id: lineID, kind: .context,
                                               text: String(line.dropFirst()),
                                               oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            default:
                // A truly empty line inside a hunk is a context line whose single leading
                // space git dropped. Treating it as a header would silently desynchronise
                // every line number after it.
                if line.isEmpty {
                    current?.lines.append(DiffLine(id: lineID, kind: .context, text: "",
                                                   oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        closeCurrent()
        return FileDiff(path: path, side: side, hunks: hunks, isBinary: false)
    }

    /// `@@ -12,7 +12,9 @@ func something()`
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int, heading: String)? {
        guard let closing = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
        else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: 2)..<closing.lowerBound]
        let heading = String(line[closing.upperBound...]).trimmingCharacters(in: .whitespaces)

        var oldStart = 0, newStart = 0
        for token in ranges.split(separator: " ") {
            let numbers = token.dropFirst().split(separator: ",")
            guard let first = numbers.first, let value = Int(first) else { continue }
            if token.hasPrefix("-") { oldStart = value }
            if token.hasPrefix("+") { newStart = value }
        }
        return (oldStart, newStart, heading)
    }

    // MARK: - Intra-line highlighting

    /// Mark what actually changed inside a modified line.
    ///
    /// This is most of the value of rendering a diff in-app rather than shelling to a pager:
    /// a one-character change in a long line is invisible when the whole line is coloured.
    static func emphasise(_ lines: [DiffLine]) -> [DiffLine] {
        var lines = lines
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deletion else { index += 1; continue }
            let deletionStart = index
            while index < lines.count, lines[index].kind == .deletion { index += 1 }
            let additionStart = index
            while index < lines.count, lines[index].kind == .addition { index += 1 }

            let deletions = deletionStart..<additionStart
            let additions = additionStart..<index
            // Only pair runs of equal length. Unequal runs mean lines were inserted or
            // removed, and pairing them by position would highlight unrelated text.
            guard deletions.count == additions.count else { continue }

            for offset in 0..<deletions.count {
                let old = lines[deletions.lowerBound + offset]
                let new = lines[additions.lowerBound + offset]
                guard let (oldRange, newRange) = changedRegion(old.text, new.text) else { continue }
                lines[deletions.lowerBound + offset].emphasis = [oldRange]
                lines[additions.lowerBound + offset].emphasis = [newRange]
            }
        }
        return lines
    }

    /// The span that differs, found by trimming the common prefix and suffix.
    ///
    /// Returns nil when the two lines share too little to be a "modification" — highlighting
    /// the whole of both lines says nothing the colour did not already say.
    static func changedRegion(_ old: String, _ new: String) -> (Range<Int>, Range<Int>)? {
        let oldChars = Array(old), newChars = Array(new)
        guard !oldChars.isEmpty || !newChars.isEmpty else { return nil }

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let shared = prefix + suffix
        let shorter = min(oldChars.count, newChars.count)
        guard shorter > 0, Double(shared) / Double(shorter) >= 0.3 else { return nil }

        let oldRange = prefix..<(oldChars.count - suffix)
        let newRange = prefix..<(newChars.count - suffix)
        guard !oldRange.isEmpty || !newRange.isEmpty else { return nil }
        return (oldRange, newRange)
    }
}
