import Foundation

/// One file an edit touched, and by how much.
///
/// What the chat shows for a change — the name and a `+12 −3` — since the change itself
/// is in the editor a click away. Counted where the change is known: from the arguments
/// of a Claude Code edit, which carries the old and new text, and from the unified diff
/// Codex reports when its edit completes.
public struct ChatFileChange: Codable, Equatable, Hashable, Sendable {
    /// The file, as the engine named it: absolute for both engines.
    public var path: String
    public var additions: Int
    public var deletions: Int

    public init(path: String, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }

    // MARK: - Counting

    /// Lines added and removed between two texts, the way `diff` counts them: lines the
    /// two have in common, in order, are matched once; what is left is a deletion on the
    /// old side and an addition on the new.
    ///
    /// A longest-common-subsequence over lines, in one rolling row. Quadratic, which is
    /// nothing for the snippets an edit swaps; anything bigger than a whole large file is
    /// counted as all-old-out, all-new-in rather than stalling a turn.
    public static func counts(from old: String, to new: String) -> (additions: Int, deletions: Int) {
        let before = lines(old)
        let after = lines(new)
        guard !before.isEmpty, !after.isEmpty else { return (after.count, before.count) }
        guard before.count * after.count <= 16_000_000 else { return (after.count, before.count) }
        var previous = [Int](repeating: 0, count: after.count + 1)
        var current = previous
        for line in before {
            for (j, other) in after.enumerated() {
                current[j + 1] = line == other ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
        }
        let common = previous[after.count]
        return (after.count - common, before.count - common)
    }

    /// Lines added and removed, read off a unified diff: every `+` and `-` line that is
    /// not the `+++`/`---` file header.
    public static func counts(ofUnifiedDiff diff: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    /// How many lines a text is, with a trailing newline not counted as an empty line
    /// and nothing counting as nothing.
    public static func lineCount(_ text: String) -> Int { lines(text).count }

    private static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
