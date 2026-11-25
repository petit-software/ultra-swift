import Foundation

/// A pane's screen, cut down to what a small window can show: the answer window mirrors
/// the bottom of a waiting agent's pane at a third of its width.
///
/// An agent draws for the pane it is in — boxes ruled edge to edge, a prompt between two
/// rules a hundred and fifty columns long. Wrapped into fifty columns those are rows of
/// `─` with the question lost between them. So the drawing goes and the words stay: a
/// box's sides are taken off the line they frame, a line that is only a rule becomes a
/// gap, gaps close up to one, and the indent every line shares is dropped. What is left
/// wraps as text does.
///
/// Read from the screen, never asked of the agent, like everything else that tells what
/// an agent is doing (`AgentPrompt`).
public enum AnswerScreen {
    /// How many rows the window shows.
    public static let limit = 16
    /// How many rows of the pane are read to find them: more than `limit`, since rules
    /// and doubled gaps are dropped on the way.
    public static let reads = 40

    public static func lines(from screen: [String], limit: Int = AnswerScreen.limit) -> [String] {
        var cleaned: [String] = []
        for line in screen {
            let text = unframed(line)
            // A gap is kept, once: it is what separates the question from its choices.
            if text.isEmpty, cleaned.last?.isEmpty ?? true { continue }
            cleaned.append(text)
        }
        while cleaned.last?.isEmpty == true { cleaned.removeLast() }
        let tail = Array(cleaned.suffix(limit).drop { $0.isEmpty })
        let indent = tail.filter { !$0.isEmpty }
            .map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return tail.map { String($0.dropFirst(min(indent, $0.count))) }
    }

    /// One line without the box around it: a side at either end goes, with the space
    /// inside it; a line of nothing but drawing is empty. The indent inside the box
    /// stays, since a list of choices is aligned by it.
    static func unframed(_ line: String) -> String {
        var scalars = Array(line.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        guard scalars.contains(where: { !isDrawing($0) && !$0.properties.isWhitespace }) else { return "" }
        if let last = scalars.last, isDrawing(last) {
            scalars.removeLast()
            while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        }
        let lead = scalars.prefix { $0.properties.isWhitespace }.count
        if lead < scalars.count, isDrawing(scalars[lead]) {
            // The side, and the one space of padding a box keeps inside it.
            var cut = lead + 1
            if cut < scalars.count, scalars[cut] == " " { cut += 1 }
            scalars.removeSubrange(0..<cut)
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars)
        return String(text)
    }

    /// Box drawing and block elements: what a frame or a rule is made of.
    static func isDrawing(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259f).contains(scalar.value)
    }
}
