import Foundation

/// Markdown, coloured as the prose it is.
///
/// The generic colouriser is a table of a dozen facts — what a comment starts with, what a
/// string is wrapped in — and Markdown has none of those. What makes a `.md` file readable
/// at a glance is its STRUCTURE: the headings, the list bullets, the fenced code, the links.
/// So this is a second scanner rather than a thirtieth table, and the only one: a line at a
/// time, because every Markdown construct that matters either owns its line (a heading, a
/// fence, a bullet) or lives inside one (emphasis, a code span, a link).
///
/// Not CommonMark. Nested lists, lazy continuation, link reference resolution and the
/// forty rules about delimiter runs are a parser's work, and the editor is for fixing a
/// README without leaving the terminal. What is here is what the eye uses: it gets the
/// common cases right, and an odd case is uncoloured text rather than wrong colour.
///
/// Pure, the same as `CodeHighlighter.tokens`: text in, UTF-16 ranges out.
enum MarkdownHighlighter {

    static func tokens(in text: String) -> [CodeToken] {
        let chars = Array(text.utf16)
        let count = chars.count
        var tokens: [CodeToken] = []
        var lineStart = 0
        var lineNumber = 0
        /// The run of backticks or tildes that opened the fenced block the scan is in.
        var fence: [UInt16]?
        var inFrontMatter = false
        var inComment = false
        /// The last line, if it was paragraph text — the only kind a `===` or `---` under
        /// it turns into a heading.
        var paragraphAbove: NSRange?

        func emit(_ start: Int, _ end: Int, _ kind: CodeTokenKind) {
            guard end > start else { return }
            tokens.append(CodeToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count, !isNewline(chars[lineEnd]) { lineEnd += 1 }
            var next = lineEnd + 1
            if lineEnd + 1 < count, chars[lineEnd] == cr, chars[lineEnd + 1] == lf { next += 1 }
            defer { lineStart = next; lineNumber += 1 }

            let line = chars[lineStart..<lineEnd]
            let isBlank = line.allSatisfy(isSpace)

            // Front matter: a `---` on the very first line, through the next one.
            if lineNumber == 0, isRule(line, of: dash, exactly: 3) {
                inFrontMatter = true
                emit(lineStart, lineEnd, .comment)
                continue
            }
            if inFrontMatter {
                emit(lineStart, lineEnd, .comment)
                if isRule(line, of: dash, exactly: 3) || isRule(line, of: dot, exactly: 3) { inFrontMatter = false }
                continue
            }

            // An HTML comment that opened on an earlier line.
            if inComment {
                if let close = find(commentClose, in: chars, from: lineStart, to: lineEnd) {
                    emit(lineStart, close + commentClose.count, .comment)
                    inComment = false
                    scanInline(chars, from: close + commentClose.count, to: lineEnd, emit: emit, inComment: &inComment)
                } else {
                    emit(lineStart, lineEnd, .comment)
                }
                paragraphAbove = nil
                continue
            }

            // Fenced code: everything between the fences is code and nothing else — a `#`
            // in a shell snippet is a comment, not a heading.
            let indent = leadingSpaces(line)
            if let open = fence {
                if indent <= 3, let run = fenceRun(line, from: indent), run.count >= open.count, run[0] == open[0] {
                    emit(lineStart, lineEnd, .marker)
                    fence = nil
                } else {
                    emit(lineStart, lineEnd, .code)
                }
                paragraphAbove = nil
                continue
            }
            if indent <= 3, let run = fenceRun(line, from: indent) {
                fence = run
                emit(lineStart, lineEnd, .marker)
                paragraphAbove = nil
                continue
            }

            if isBlank {
                paragraphAbove = nil
                continue
            }

            // A line of `===` or `---` under a paragraph makes that paragraph a heading.
            if let above = paragraphAbove, indent <= 3,
               isRule(line, of: equals, exactly: nil) || isRule(line, of: dash, exactly: nil) {
                emit(above.location, above.location + above.length, .heading)
                emit(lineStart, lineEnd, .heading)
                paragraphAbove = nil
                continue
            }

            var position = lineStart + indent
            var isParagraph = true

            // Block quote: the `>` marks, however many deep.
            if position < lineEnd, chars[position] == greaterThan {
                let start = position
                while position < lineEnd, chars[position] == greaterThan || isSpace(chars[position]) { position += 1 }
                var marksEnd = position
                while marksEnd > start, isSpace(chars[marksEnd - 1]) { marksEnd -= 1 }
                emit(start, marksEnd, .marker)
                isParagraph = false
            }

            // A thematic break: `---`, `* * *`, `___`.
            if isRule(chars[position..<lineEnd], of: dash, exactly: nil)
                || isRule(chars[position..<lineEnd], of: asterisk, exactly: nil)
                || isRule(chars[position..<lineEnd], of: underscore, exactly: nil) {
                emit(position, lineEnd, .marker)
                paragraphAbove = nil
                continue
            }

            // ATX heading: `#` to `######`, then a space. The whole line is the heading;
            // emphasis inside it is not picked apart, a heading is already loud.
            if position < lineEnd, chars[position] == hash {
                var hashes = position
                while hashes < lineEnd, chars[hashes] == hash { hashes += 1 }
                if hashes - position <= 6, hashes == lineEnd || isSpace(chars[hashes]) {
                    emit(position, lineEnd, .heading)
                    paragraphAbove = nil
                    continue
                }
            }

            // A list item: its bullet or number, then a task box if it has one.
            if let markerEnd = listMarkerEnd(chars, from: position, to: lineEnd) {
                emit(position, markerEnd, .marker)
                position = markerEnd
                while position < lineEnd, isSpace(chars[position]) { position += 1 }
                if position + 3 <= lineEnd, chars[position] == openBracket, chars[position + 2] == closeBracket,
                   isSpace(chars[position + 1]) || chars[position + 1] == letterX || chars[position + 1] == upperX,
                   position + 3 == lineEnd || isSpace(chars[position + 3]) {
                    emit(position, position + 3, .marker)
                    position += 3
                }
                isParagraph = false
            }

            // A link definition: `[name]: url`.
            if position < lineEnd, chars[position] == openBracket,
               let close = find([closeBracket, colon], in: chars, from: position, to: lineEnd) {
                emit(position, close + 2, .link)
                emit(close + 2, lineEnd, .comment)
                paragraphAbove = nil
                continue
            }

            scanInline(chars, from: position, to: lineEnd, emit: emit, inComment: &inComment)
            paragraphAbove = isParagraph ? NSRange(location: lineStart, length: lineEnd - lineStart) : nil
        }
        return tokens
    }

    // MARK: Inline

    /// Code spans, emphasis, links and comments inside one line. A code span swallows the
    /// emphasis marks inside it, and emphasis swallows what it wraps: longest first, the
    /// same rule as the generic scanner.
    private static func scanInline(_ chars: [UInt16], from start: Int, to end: Int,
                                   emit: (Int, Int, CodeTokenKind) -> Void,
                                   inComment: inout Bool) {
        var index = start
        while index < end {
            let unit = chars[index]

            if unit == backslash { index = min(end, index + 2); continue }

            // A code span closes at a run of backticks exactly as long as the one that
            // opened it, so `` `a` `` holds a backtick.
            if unit == backtick {
                var runEnd = index
                while runEnd < end, chars[runEnd] == backtick { runEnd += 1 }
                let length = runEnd - index
                var scan = runEnd
                var closed: Int?
                while scan < end {
                    if chars[scan] == backtick {
                        var closeEnd = scan
                        while closeEnd < end, chars[closeEnd] == backtick { closeEnd += 1 }
                        if closeEnd - scan == length { closed = closeEnd; break }
                        scan = closeEnd
                    } else {
                        scan += 1
                    }
                }
                if let closed {
                    emit(index, closed, .code)
                    index = closed
                } else {
                    index = runEnd
                }
                continue
            }

            if matches(commentOpen, chars, at: index, before: end) {
                if let close = find(commentClose, in: chars, from: index + commentOpen.count, to: end) {
                    emit(index, close + commentClose.count, .comment)
                    index = close + commentClose.count
                } else {
                    emit(index, end, .comment)
                    inComment = true
                    index = end
                }
                continue
            }

            // `[text](url)`, `![alt](src)`, `[text][ref]`: the text is the link, the
            // destination recedes — it is the part nobody reads.
            if unit == openBracket || (unit == bang && index + 1 < end && chars[index + 1] == openBracket) {
                let textStart = index
                let bracket = unit == bang ? index + 1 : index
                if let textClose = find([closeBracket], in: chars, from: bracket + 1, to: end) {
                    let after = textClose + 1
                    if after < end, chars[after] == openParen,
                       let close = find([closeParen], in: chars, from: after + 1, to: end) {
                        emit(textStart, after, .link)
                        emit(after, close + 1, .comment)
                        index = close + 1
                        continue
                    }
                    if after < end, chars[after] == openBracket,
                       let close = find([closeBracket], in: chars, from: after + 1, to: end) {
                        emit(textStart, close + 1, .link)
                        index = close + 1
                        continue
                    }
                }
                index = bracket + 1
                continue
            }

            // `<https://…>` and a bare `https://…`.
            if unit == lessThan, let close = find([greaterThan], in: chars, from: index + 1, to: end),
               find(schemeSeparator, in: chars, from: index + 1, to: close) != nil,
               !chars[index + 1..<close].contains(where: isSpace) {
                emit(index, close + 1, .link)
                index = close + 1
                continue
            }
            if (matches(httpPrefix, chars, at: index, before: end) || matches(httpsPrefix, chars, at: index, before: end)),
               index == start || !isWord(chars[index - 1]) {
                var urlEnd = index
                while urlEnd < end, !isSpace(chars[urlEnd]), chars[urlEnd] != lessThan, chars[urlEnd] != greaterThan { urlEnd += 1 }
                // Punctuation after a URL is the sentence's, not the address's.
                while urlEnd > index, [dot, comma, closeParen, semicolon, colon, bang, question].contains(chars[urlEnd - 1]) { urlEnd -= 1 }
                emit(index, urlEnd, .link)
                index = urlEnd
                continue
            }

            // `*em*`, `**strong**`, `_em_`, `__strong__`. The run has to be followed by
            // something that is not a space to open, and the closing run preceded by one.
            // An underscore only counts at a word edge: `snake_case_name` is a name.
            if unit == asterisk || unit == underscore {
                var runEnd = index
                while runEnd < end, chars[runEnd] == unit { runEnd += 1 }
                let length = runEnd - index
                let wordBefore = index > start && isWord(chars[index - 1])
                let canOpen = runEnd < end && !isSpace(chars[runEnd]) && (unit == asterisk || !wordBefore)
                if canOpen, length <= 3, let close = closingRun(of: unit, length: length, in: chars, from: runEnd, to: end) {
                    emit(index, close, length == 1 ? .emphasis : .strong)
                    index = close
                } else {
                    index = runEnd
                }
                continue
            }

            index += 1
        }
    }

    /// The end of the first run of `unit` that is at least `length` long and can close:
    /// not preceded by a space, and for an underscore not followed by a word character.
    private static func closingRun(of unit: UInt16, length: Int, in chars: [UInt16], from start: Int, to end: Int) -> Int? {
        var index = start
        while index < end {
            if chars[index] == unit {
                var runEnd = index
                while runEnd < end, chars[runEnd] == unit { runEnd += 1 }
                let wordAfter = runEnd < end && isWord(chars[runEnd])
                if runEnd - index >= length, !isSpace(chars[index - 1]), unit == asterisk || !wordAfter {
                    return index + length
                }
                index = runEnd
            } else {
                index += 1
            }
        }
        return nil
    }

    // MARK: Lines

    private static func leadingSpaces(_ line: ArraySlice<UInt16>) -> Int {
        var count = 0
        for unit in line where isSpace(unit) { count += 1 }
        return min(count, line.prefix { isSpace($0) }.count)
    }

    /// Three or more backticks or tildes, as the run itself. Nil when the line does not
    /// open or close a fence.
    private static func fenceRun(_ line: ArraySlice<UInt16>, from indent: Int) -> [UInt16]? {
        let start = line.startIndex + indent
        guard start < line.endIndex, line[start] == backtick || line[start] == tilde else { return nil }
        let unit = line[start]
        var runEnd = start
        while runEnd < line.endIndex, line[runEnd] == unit { runEnd += 1 }
        guard runEnd - start >= 3 else { return nil }
        // A backtick fence's info string may not hold a backtick: that is a code span.
        if unit == backtick, line[runEnd...].contains(backtick) { return nil }
        return Array(line[start..<runEnd])
    }

    /// A line that is only `unit`, three or more of it, with spaces between or after —
    /// or exactly `exactly` of it, for the front matter's `---`.
    private static func isRule(_ line: ArraySlice<UInt16>, of unit: UInt16, exactly: Int?) -> Bool {
        var seen = 0
        for char in line {
            if char == unit { seen += 1 } else if !isSpace(char) { return false }
        }
        if let exactly { return seen == exactly && line.count == exactly }
        return seen >= 3
    }

    /// Where a list item's `-`, `*`, `+` or `12.` ends, or nil when the line is not one.
    private static func listMarkerEnd(_ chars: [UInt16], from start: Int, to end: Int) -> Int? {
        guard start < end else { return nil }
        let unit = chars[start]
        if unit == dash || unit == asterisk || unit == plus {
            return start + 1 == end || isSpace(chars[start + 1]) ? start + 1 : nil
        }
        var index = start
        while index < end, index - start < 9, isDigit(chars[index]) { index += 1 }
        guard index > start, index < end, chars[index] == dot || chars[index] == closeParen else { return nil }
        return index + 1 == end || isSpace(chars[index + 1]) ? index + 1 : nil
    }

    // MARK: Code units

    private static func matches(_ pattern: [UInt16], _ chars: [UInt16], at position: Int, before end: Int) -> Bool {
        guard position + pattern.count <= end else { return false }
        for offset in pattern.indices where chars[position + offset] != pattern[offset] { return false }
        return true
    }

    private static func find(_ pattern: [UInt16], in chars: [UInt16], from start: Int, to end: Int) -> Int? {
        guard pattern.count <= end - start else { return nil }
        for position in start...(end - pattern.count) where matches(pattern, chars, at: position, before: end) {
            return position
        }
        return nil
    }

    private static let cr: UInt16 = 13
    private static let lf: UInt16 = 10
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let tilde = UInt16(UInt8(ascii: "~"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let dash = UInt16(UInt8(ascii: "-"))
    private static let plus = UInt16(UInt8(ascii: "+"))
    private static let asterisk = UInt16(UInt8(ascii: "*"))
    private static let underscore = UInt16(UInt8(ascii: "_"))
    private static let equals = UInt16(UInt8(ascii: "="))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let comma = UInt16(UInt8(ascii: ","))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let semicolon = UInt16(UInt8(ascii: ";"))
    private static let bang = UInt16(UInt8(ascii: "!"))
    private static let question = UInt16(UInt8(ascii: "?"))
    private static let greaterThan = UInt16(UInt8(ascii: ">"))
    private static let lessThan = UInt16(UInt8(ascii: "<"))
    private static let openBracket = UInt16(UInt8(ascii: "["))
    private static let closeBracket = UInt16(UInt8(ascii: "]"))
    private static let openParen = UInt16(UInt8(ascii: "("))
    private static let closeParen = UInt16(UInt8(ascii: ")"))
    private static let letterX = UInt16(UInt8(ascii: "x"))
    private static let upperX = UInt16(UInt8(ascii: "X"))
    private static let commentOpen = Array("<!--".utf16)
    private static let commentClose = Array("-->".utf16)
    private static let schemeSeparator = Array("://".utf16)
    private static let httpPrefix = Array("http://".utf16)
    private static let httpsPrefix = Array("https://".utf16)

    private static func isNewline(_ unit: UInt16) -> Bool { unit == lf || unit == cr }
    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }
    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    private static func isWord(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == underscore || unit >= 0x80
    }
}
