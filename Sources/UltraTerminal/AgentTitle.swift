import Foundation

/// The title an agent carries: what it set on its terminal, as a row can show it.
///
/// An agent's TUI names its pane after the work in hand — "Fix the orders 404" — and
/// leads the name with a glyph that says whether it is working: Claude Code's `✳`, or a
/// braille frame that changes several times a second. The glyph is a status, which the
/// row has a symbol of its own for, and one that changes is a row that redraws; so it is
/// dropped, and what is left is the title.
public enum AgentTitle {
    /// The title without its leading status glyphs, or nil if nothing is left — or if what
    /// is left is only the agent's own name, which says nothing the row's mark does not.
    public static func active(_ reported: String?, agentName: String? = nil) -> String? {
        guard let reported else { return nil }
        let scalars = reported.unicodeScalars.drop(while: isLeadingMark)
        let title = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        if let agentName, title.caseInsensitiveCompare(agentName) == .orderedSame { return nil }
        return title
    }

    private static func isLeadingMark(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .format, .nonspacingMark: return true
        default: return "*·•".unicodeScalars.contains(scalar)
        }
    }
}
