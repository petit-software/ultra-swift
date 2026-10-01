import Foundation

/// The files a shell command adds or removes, read off the command itself.
///
/// An engine deletes a file the way anyone does, with `rm` in a command, and the chat
/// would otherwise show that as one more terminal row — a `+`/`−` table that lists the
/// files an answer edited but not the one it deleted is wrong about what happened. So the
/// commands that plainly make or unmake a file are read: `rm`, `git rm`, `mv` (the source
/// gone, the destination new) and `touch`. Anything else a command does to files — a
/// redirect, a script, `cp` into a folder — is not guessed at; it stays a plain row.
public enum CommandChanges {

    /// The changes a command spells out, in the order written. A deleted file is counted
    /// from disk while it is still there, which is now: the call is announced before it
    /// runs. Paths are left as written, relative to the project.
    public static func changes(in command: String, under directory: URL? = nil) -> [ChatFileChange] {
        var changes: [ChatFileChange] = []
        for segment in segments(of: command) {
            var words = segment
            // `sudo rm`, `FOO=1 rm`: the command is after the prefix.
            while let first = words.first, first == "sudo" || first.isEnvironmentAssignment { words.removeFirst() }
            guard let head = words.first else { continue }
            let arguments = Array(words.dropFirst())
            switch head {
            case "rm":
                for path in operands(of: arguments) { changes.append(deleted(path, under: directory)) }
            case "git":
                guard arguments.first == "rm" else { continue }
                for path in operands(of: Array(arguments.dropFirst())) { changes.append(deleted(path, under: directory)) }
            case "mv":
                let paths = operands(of: arguments)
                guard paths.count == 2 else { continue }
                let gone = deleted(paths[0], under: directory)
                changes.append(gone)
                changes.append(ChatFileChange(path: paths[1], additions: gone.deletions, kind: .added))
            case "touch":
                for path in operands(of: arguments) {
                    // Touching a file that exists changes nothing worth a row.
                    guard ChatFileChange.text(ofFileAt: url(of: path, under: directory)) == nil else { continue }
                    changes.append(ChatFileChange(path: path, kind: .added))
                }
            default:
                continue
            }
        }
        return changes
    }

    private static func deleted(_ path: String, under directory: URL?) -> ChatFileChange {
        let lines = ChatFileChange.text(ofFileAt: url(of: path, under: directory)).map(ChatFileChange.lineCount) ?? 0
        return ChatFileChange(path: path, deletions: lines, kind: .deleted)
    }

    private static func url(of path: String, under directory: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return (directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(expanded)
    }

    /// The words that are files: flags dropped, and everything after `--` taken as one.
    /// A glob is not a file; it is left out rather than shown as one named `*.log`.
    private static func operands(of arguments: [String]) -> [String] {
        var paths: [String] = []
        var literal = false
        for word in arguments {
            if !literal, word == "--" { literal = true; continue }
            if !literal, word.hasPrefix("-") { continue }
            if word.contains("*") || word.contains("?") || word.contains("{") { continue }
            paths.append(word)
        }
        return paths
    }

    /// The command as simple commands, each as words: split at `&&`, `||`, `;`, `|` and
    /// newlines outside quotes, with quotes and backslashes resolved the way the shell
    /// would for a plain word.
    static func segments(of command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var characters = Array(command)
        characters.append("\n")
        var index = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\", index + 1 < characters.count,
                          ["\"", "\\", "$", "`"].contains(characters[index + 1]) {
                    index += 1
                    word.append(characters[index])
                } else {
                    word.append(character)
                }
            } else {
                switch character {
                case "'", "\"":
                    quote = character
                    inWord = true
                case "\\":
                    if index + 1 < characters.count, characters[index + 1] != "\n" {
                        index += 1
                        word.append(characters[index])
                        inWord = true
                    }
                case ";", "\n":
                    endSegment()
                case "|":
                    endSegment()
                    if index + 1 < characters.count, characters[index + 1] == "|" { index += 1 }
                case "&":
                    endSegment()
                    if index + 1 < characters.count, characters[index + 1] == "&" { index += 1 }
                case " ", "\t":
                    endWord()
                default:
                    word.append(character)
                    inWord = true
                }
            }
            index += 1
        }
        endSegment()
        return segments
    }
}

private extension String {
    /// `FOO=bar`: a variable set for the command that follows, not the command.
    var isEnvironmentAssignment: Bool {
        guard let equals = firstIndex(of: "="), equals != startIndex else { return false }
        return self[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
