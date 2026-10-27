import Foundation

/// A path as it can be typed at a shell prompt.
///
/// Backslash escapes, the way Terminal.app writes a dropped file, rather than quotes:
/// an escaped path is still one word the shell's completion can extend, and a quoted one
/// is a string the cursor has to be moved inside first. Every byte that is not plainly
/// safe is escaped — the set of characters a shell gives meaning to is longer than anyone
/// remembers, and a path escaped too much is still the path, while one escaped too little
/// is a different command.
public enum ShellQuote {
    /// Characters that mean nothing special to any shell, left as they are.
    private static let plain: Set<Character> = {
        var set = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.formUnion("/._-+:,@%")
        return set
    }()

    /// One path, escaped for a prompt.
    public static func escaped(_ path: String) -> String {
        var out = ""
        for character in path {
            if plain.contains(character) {
                out.append(character)
            } else if character == "\n" {
                // The one byte a backslash cannot carry: backslash-newline is a line
                // continuation, and the newline is gone. `$'\n'` is the one spelling both
                // zsh and bash read as the byte itself.
                out.append("$'\\n'")
            } else {
                out.append("\\")
                out.append(character)
            }
        }
        return out
    }

    /// Several dropped files as one line of input: each escaped, a space between, and a
    /// space after the last so what is typed next is a new word rather than part of the
    /// path.
    public static func line(_ paths: [String]) -> String {
        paths.isEmpty ? "" : paths.map(escaped).joined(separator: " ") + " "
    }
}
