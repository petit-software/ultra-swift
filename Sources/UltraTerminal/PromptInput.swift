import Foundation

/// How much of a line the user has typed at the prompt, counted from the bytes sent.
///
/// The `@` and `/` pickers open only on the FIRST character of a line: `cd /tmp` and an
/// email address must reach the shell untouched, and a prompt that already has words in
/// it is being written, not started. The terminal cannot ask the agent where its caret
/// is, but it sees every byte the user sends, and a count that goes up on a printable
/// byte, down on a backspace and back to zero on Return, ^C or ^U is right whenever it
/// matters: at the start of a line it is zero, and after any typing it is not.
///
/// An escape sequence — an arrow, a function key — is skipped whole: it starts with ESC
/// and SwiftTerm sends each key as its own chunk, so the chunk is the sequence.
public enum PromptInput {

    public static func length(after bytes: ArraySlice<UInt8>, from current: Int) -> Int {
        guard bytes.first != 0x1b else { return current }
        var length = current
        for byte in bytes {
            switch byte {
            case 0x0d, 0x0a, 0x03, 0x15: length = 0          // CR, LF, ^C, ^U
            case 0x7f, 0x08: length = max(0, length - 1)     // DEL, BS
            case 0x20...: length += 1
            default: break
            }
        }
        return length
    }
}
