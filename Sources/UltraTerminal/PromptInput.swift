import Foundation

/// Whether the caret is at the start of a line at an agent's prompt, read from the screen.
///
/// The `@` and `/` pickers open only on the FIRST character of a line: `cd /tmp` and an
/// email address must reach the agent untouched, and a prompt that already has words in
/// it is being written, not started. The terminal cannot ask the agent where its caret
/// is, but it can see the row the caret is on: a line is empty when nothing is drawn
/// before the caret but the agent's prompt marker — `❯`, `>`, `›` — and the box it sits in.
///
/// Read from the screen rather than counted from the bytes the user sent. A count went
/// up on a printable byte and back to zero on Return, ^C or ^U, which is right only while
/// those keys ARE those bytes. Claude Code turns on the kitty keyboard protocol, under
/// which ^C is `ESC [ 99 ; 5 u`, ^U is `ESC [ 117 ; 5 u` and Esc is `ESC [ 27 u`; the agent
/// clears its line, the count never hears of it, and the pickers never open again until
/// the next Return. ⌥⌫ deletes a word and counts as one character. The screen is what
/// the agent actually did with the keys, whatever they were.
public enum PromptInput {

    /// Whether `text` — what is drawn on the caret's row before the caret — is an empty
    /// prompt: blank, or a single marker that is not a letter or a digit, once the box
    /// drawing around it is ignored. `❯ `, `> `, `│ > ` and a bare continuation line are
    /// empty; `❯ @`, `> hello`, `cd ` and `❯ 1` are not.
    public static func isLineStart(before text: String) -> Bool {
        var marker: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7f { continue }
            if (0x2500...0x259f).contains(scalar.value) { continue }   // box drawing, block elements
            guard marker == nil else { return false }                    // a second thing: typing
            marker = scalar
        }
        guard let marker else { return true }
        return !(marker.properties.isAlphabetic || marker.properties.numericType != nil)
    }
}
