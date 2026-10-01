import Foundation

/// One file a change touched, how, and by how much.
///
/// What the chat shows for a change — the name, what became of it, and a `+12 −3` — since
/// the change itself is in the editor a click away. Counted where the change is known:
/// from the arguments of a Claude Code edit, which carries the old and new text, from the
/// file on disk when a command removes it, and from the unified diff Codex reports when
/// its edit completes.
public struct ChatFileChange: Codable, Equatable, Hashable, Sendable {
    /// What became of the file. An edit is the usual case; a file written where there was
    /// none is added, and one a command removed is deleted.
    public enum Kind: String, Codable, Sendable {
        case modified
        case added
        case deleted
    }

    /// The file, as the engine named it: absolute for both engines, relative to the
    /// project for a path in a command.
    public var path: String
    public var additions: Int
    public var deletions: Int
    public var kind: Kind

    public init(path: String, additions: Int = 0, deletions: Int = 0, kind: Kind = .modified) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case path, additions, deletions, kind
    }

    /// A change saved before kinds existed is an edit, which is all there was.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        additions = try container.decode(Int.self, forKey: .additions)
        deletions = try container.decode(Int.self, forKey: .deletions)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .modified
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

    /// The text of a file on disk, when it is one: nil for a path that is not there, a
    /// folder, something that is not UTF-8, or a file too big to be worth reading for a
    /// line count (4 MB).
    public static func text(ofFileAt url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 4_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
