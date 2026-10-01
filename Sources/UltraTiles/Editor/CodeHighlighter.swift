import Foundation

/// What a run of source is, for colouring. A dozen kinds, not a grammar.
///
/// A generic colouriser rather than a parser per language: the editor is for fixing a
/// config file without leaving the terminal, and what makes a file readable at a glance is
/// the same everywhere — comments recede, strings and numbers stand apart from code, and
/// the keywords give the shape. Anything finer is the job of the editor the user already
/// has.
///
/// The second half is Markdown's, where the shape is structure rather than syntax: a
/// heading, a list bullet, a code span, a link. See `MarkdownHighlighter`.
public enum CodeTokenKind: Equatable, Sendable {
    case keyword, string, comment, number, type, attribute
    /// A heading line, `#` to `######` or underlined.
    case heading
    /// `**strong**` and `*emphasis*`, marks included.
    case strong, emphasis
    /// A code span, or a line inside a fenced block.
    case code
    /// A link's text, an autolink, a bare URL, a reference definition's name.
    case link
    /// Structure that is not content: a bullet, a number, a task box, a quote mark, a
    /// rule, a fence line.
    case marker
}

public struct CodeToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: CodeTokenKind

    public init(range: NSRange, kind: CodeTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// The handful of facts about a language the colouriser needs: how a comment starts, what
/// a string is wrapped in, which words are keywords.
///
/// One table per language rather than one grammar per language — every entry here is a
/// dozen lines, and a file in a language nobody thought of is plain text, not an error.
public struct CodeLanguage: Equatable, Sendable {
    struct BlockComment: Equatable, Sendable {
        let open: [UInt16]
        let close: [UInt16]
        init(_ open: String, _ close: String) {
            self.open = Array(open.utf16)
            self.close = Array(close.utf16)
        }
    }

    /// How the text is scanned. The table below serves every language but one; Markdown
    /// has no comments, strings or keywords and is read line by line instead.
    enum Scanner: Equatable, Sendable { case generic, markdown }

    public let name: String
    let scanner: Scanner
    let keywords: Set<String>
    let lineComments: [[UInt16]]
    let blockComment: BlockComment?
    /// Characters a string opens with. A string closes at the same character on the same
    /// line, unless it is in `multilineQuotes` or tripled (`"""`, `'''`).
    let quotes: [UInt16]
    let multilineQuotes: [UInt16]
    let tripleQuotes: Bool
    /// Characters that make the identifier after them an attribute: `@State`, `#include`,
    /// `$HOME`.
    let sigils: [UInt16]
    /// Whether a capitalised identifier is a type — true for the languages that follow the
    /// convention, false where variables are as often capitalised as not.
    let capitalisedTypes: Bool

    init(name: String, keywords: String, lineComments: [String] = [],
         blockComment: BlockComment? = nil, quotes: String = "\"'",
         multilineQuotes: String = "", tripleQuotes: Bool = false, sigils: String = "",
         capitalisedTypes: Bool = true, scanner: Scanner = .generic) {
        self.name = name
        self.scanner = scanner
        self.keywords = Set(keywords.split(separator: " ").map(String.init))
        self.lineComments = lineComments.map { Array($0.utf16) }
        self.blockComment = blockComment
        self.quotes = Array(quotes.utf16)
        self.multilineQuotes = Array(multilineQuotes.utf16)
        self.tripleQuotes = tripleQuotes
        self.sigils = Array(sigils.utf16)
        self.capitalisedTypes = capitalisedTypes
    }

    // MARK: Detection

    /// The language a file is in, by its name. Nil for one nobody here recognises, which
    /// is shown as plain text.
    public static func detect(path: String) -> CodeLanguage? {
        let name = (path as NSString).lastPathComponent
        switch name.lowercased() {
        case "makefile", "gnumakefile": return .makefile
        case "dockerfile", "containerfile": return .dockerfile
        case "gemfile", "rakefile", "podfile", "fastfile", "brewfile": return .ruby
        case "cmakelists.txt": return .cmake
        // Prose files that go without an extension more often than not.
        case "readme", "changelog", "contributing": return .markdown
        default: break
        }
        return byExtension[(name as NSString).pathExtension.lowercased()]
    }

    /// For a file with no telling extension: the interpreter its first line names.
    public static func detect(shebang firstLine: some StringProtocol) -> CodeLanguage? {
        let line = String(firstLine)
        guard line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        // `#!/usr/bin/env python3` names the interpreter second; `#!/bin/sh` names it first.
        var interpreter = words.first.map { ($0 as NSString).lastPathComponent } ?? ""
        if interpreter == "env", words.count > 1 {
            interpreter = words.dropFirst().first { !$0.hasPrefix("-") } ?? ""
        }
        let base = interpreter.lowercased().trimmingCharacters(in: .decimalDigits.union(["."]))
        switch base {
        case "sh", "bash", "zsh", "dash", "ksh", "fish": return .shell
        case "python": return .python
        case "ruby": return .ruby
        case "node", "deno", "bun": return .javascript
        case "perl": return .perl
        case "swift": return .swift
        case "lua": return .lua
        default: return nil
        }
    }

    private static let byExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "c": .c, "h": .c, "m": .objc, "mm": .objc,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "java": .java, "kt": .kotlin, "kts": .kotlin, "cs": .csharp,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript,
        "py": .python, "pyi": .python, "rb": .ruby, "go": .go, "rs": .rust,
        "php": .php, "pl": .perl, "pm": .perl, "lua": .lua, "dart": .dart,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "zshrc": .shell, "bashrc": .shell, "profile": .shell,
        "json": .json, "jsonc": .json, "yaml": .yaml, "yml": .yaml, "toml": .toml,
        "ini": .ini, "conf": .ini, "cfg": .ini, "env": .shell, "properties": .ini,
        "css": .css, "scss": .css, "less": .css,
        "html": .markup, "htm": .markup, "xml": .markup, "svg": .markup,
        "plist": .markup, "xib": .markup, "storyboard": .markup, "xsl": .markup,
        "sql": .sql, "mk": .makefile, "cmake": .cmake,
        "graphql": .graphql, "gql": .graphql, "proto": .proto,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "mdx": .markdown,
    ]

    // MARK: Languages

    static let swift = CodeLanguage(
        name: "Swift",
        keywords: "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as any false is nil self Self super throws true try async await actor nonisolated isolated some consuming borrowing macro package each willSet didSet get set mutating nonmutating override final required convenience lazy weak unowned indirect dynamic optional infix prefix postfix",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"),
        quotes: "\"", tripleQuotes: true, sigils: "@#")

    static let c = CodeLanguage(
        name: "C",
        keywords: "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex bool true false NULL",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), sigils: "#")

    static let cpp = CodeLanguage(
        name: "C++",
        keywords: c.keywords.joined(separator: " ") + " alignas alignof and asm catch class concept consteval constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export final friend mutable namespace new noexcept not nullptr operator or override private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual wchar_t xor",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), sigils: "#")

    static let objc = CodeLanguage(
        name: "Objective-C",
        keywords: c.keywords.joined(separator: " ") + " id self super nil YES NO instancetype nonatomic atomic strong weak copy assign readonly readwrite class in out inout bycopy byref oneway BOOL SEL IMP Class",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), sigils: "@#")

    static let java = CodeLanguage(
        name: "Java",
        keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try var void volatile while true false null record sealed permits yield",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), tripleQuotes: true, sigils: "@")

    static let kotlin = CodeLanguage(
        name: "Kotlin",
        keywords: "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam value where abstract actual annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), tripleQuotes: true, sigils: "@")

    static let csharp = CodeLanguage(
        name: "C#",
        keywords: "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while async await record init get set value yield when nameof",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), sigils: "#")

    static let javascript = CodeLanguage(
        name: "JavaScript",
        keywords: "async await break case catch class const continue debugger default delete do else export extends false finally for function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield get set",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"),
        quotes: "\"'`", multilineQuotes: "`", sigils: "@")

    static let typescript = CodeLanguage(
        name: "TypeScript",
        keywords: javascript.keywords.joined(separator: " ") + " abstract any as asserts boolean constructor declare enum implements interface is keyof module namespace never number object override private protected public readonly require satisfies string symbol type unique unknown",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"),
        quotes: "\"'`", multilineQuotes: "`", sigils: "@")

    static let python = CodeLanguage(
        name: "Python",
        keywords: "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls",
        lineComments: ["#"], tripleQuotes: true, sigils: "@")

    static let ruby = CodeLanguage(
        name: "Ruby",
        keywords: "BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative include extend attr_reader attr_writer attr_accessor private public protected raise lambda proc puts",
        lineComments: ["#"], blockComment: BlockComment("\n=begin", "\n=end"),
        quotes: "\"'`", sigils: "@$")

    static let go = CodeLanguage(
        name: "Go",
        keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota append cap close copy delete len make new panic print println recover string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 bool byte rune error any",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"),
        quotes: "\"'`", multilineQuotes: "`")

    static let rust = CodeLanguage(
        name: "Rust",
        keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while macro_rules union i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Some None Result Ok Err Box",
        // No single quote: `'a` is a lifetime far more often than it is a character.
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), quotes: "\"",
        multilineQuotes: "\"", sigils: "#")

    static let php = CodeLanguage(
        name: "PHP",
        keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null self parent",
        lineComments: ["//", "#"], blockComment: BlockComment("/*", "*/"), sigils: "$@")

    static let perl = CodeLanguage(
        name: "Perl",
        keywords: "my our local sub if elsif else unless while until for foreach do last next redo return package use no require BEGIN END and or not eq ne lt gt le ge cmp print printf say die warn shift unshift push pop splice defined undef ref bless",
        lineComments: ["#"], sigils: "$@%", capitalisedTypes: false)

    static let lua = CodeLanguage(
        name: "Lua",
        keywords: "and break do else elseif end false for function goto if in local nil not or repeat return then true until while self",
        lineComments: ["--"], blockComment: BlockComment("--[[", "]]"), capitalisedTypes: false)

    static let dart = CodeLanguage(
        name: "Dart",
        keywords: "abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void while with yield",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), tripleQuotes: true, sigils: "@")

    static let shell = CodeLanguage(
        name: "Shell",
        keywords: "if then else elif fi case esac for while until do done in function select time coproc export local readonly declare typeset unset shift return exit source alias set eval exec trap cd echo printf read test true false",
        lineComments: ["#"], quotes: "\"'", multilineQuotes: "\"'", sigils: "$",
        capitalisedTypes: false)

    static let makefile = CodeLanguage(
        name: "Makefile",
        keywords: "ifeq ifneq ifdef ifndef else endif include define endef export unexport override vpath",
        lineComments: ["#"], quotes: "\"'", sigils: "$", capitalisedTypes: false)

    static let dockerfile = CodeLanguage(
        name: "Dockerfile",
        keywords: "FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS",
        lineComments: ["#"], sigils: "$", capitalisedTypes: false)

    static let cmake = CodeLanguage(
        name: "CMake",
        keywords: "if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro set unset option project add_executable add_library add_subdirectory target_link_libraries target_include_directories target_compile_options target_compile_definitions find_package include message install cmake_minimum_required return break continue",
        lineComments: ["#"], quotes: "\"", sigils: "$", capitalisedTypes: false)

    static let json = CodeLanguage(
        name: "JSON", keywords: "true false null",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"), quotes: "\"",
        capitalisedTypes: false)

    static let yaml = CodeLanguage(
        name: "YAML", keywords: "true false null yes no on off True False Null Yes No On Off TRUE FALSE NULL",
        lineComments: ["#"], sigils: "&*!", capitalisedTypes: false)

    static let toml = CodeLanguage(
        name: "TOML", keywords: "true false inf nan",
        lineComments: ["#"], tripleQuotes: true, capitalisedTypes: false)

    static let ini = CodeLanguage(
        name: "INI", keywords: "true false yes no on off",
        lineComments: ["#", ";"], capitalisedTypes: false)

    static let css = CodeLanguage(
        name: "CSS", keywords: "important inherit initial unset none auto",
        blockComment: BlockComment("/*", "*/"), sigils: "@#$", capitalisedTypes: false)

    static let markup = CodeLanguage(
        name: "Markup", keywords: "",
        blockComment: BlockComment("<!--", "-->"), capitalisedTypes: false)

    static let sql = CodeLanguage(
        name: "SQL",
        keywords: "select from where and or not in is null as join inner left right outer full on group by order having limit offset insert into values update set delete create table drop alter add column primary key foreign references index view unique default constraint if exists begin commit rollback transaction case when then else end distinct union all like between exists count sum avg min max true false SELECT FROM WHERE AND OR NOT IN IS NULL AS JOIN INNER LEFT RIGHT OUTER FULL ON GROUP BY ORDER HAVING LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE DROP ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES INDEX VIEW UNIQUE DEFAULT CONSTRAINT IF EXISTS BEGIN COMMIT ROLLBACK TRANSACTION CASE WHEN THEN ELSE END DISTINCT UNION ALL LIKE BETWEEN EXISTS COUNT SUM AVG MIN MAX TRUE FALSE",
        lineComments: ["--"], blockComment: BlockComment("/*", "*/"), capitalisedTypes: false)

    static let graphql = CodeLanguage(
        name: "GraphQL",
        keywords: "query mutation subscription fragment on type interface union enum input scalar schema extend directive implements true false null",
        lineComments: ["#"], quotes: "\"", tripleQuotes: true, sigils: "@$")

    static let proto = CodeLanguage(
        name: "Protobuf",
        keywords: "syntax package import option message enum service rpc returns repeated optional required oneof map reserved extend extensions stream true false double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes",
        lineComments: ["//"], blockComment: BlockComment("/*", "*/"))

    /// No table: see `MarkdownHighlighter`.
    static let markdown = CodeLanguage(name: "Markdown", keywords: "", scanner: .markdown)
}

/// The scan itself. Pure: text and a language in, ranges out, so what gets coloured is
/// decided by numbers a test can check rather than by what a text view drew.
public enum CodeHighlighter {

    /// Every coloured run in `text`, in order, as UTF-16 ranges — the units `NSTextStorage`
    /// attributes are set in, and the reason this walks code units rather than characters.
    ///
    /// One pass, left to right, longest construct first: a comment swallows the quotes
    /// inside it, a string swallows the keywords inside it, and neither is opened by the
    /// other. That ordering is the whole of what makes a colouriser look right.
    public static func tokens(in text: String, language: CodeLanguage) -> [CodeToken] {
        if language.scanner == .markdown { return MarkdownHighlighter.tokens(in: text) }
        let chars = Array(text.utf16)
        let count = chars.count
        var tokens: [CodeToken] = []
        var index = 0

        func matches(_ pattern: [UInt16], at position: Int) -> Bool {
            guard !pattern.isEmpty, position + pattern.count <= count else { return false }
            for offset in pattern.indices where chars[position + offset] != pattern[offset] {
                return false
            }
            return true
        }
        func emit(_ start: Int, _ kind: CodeTokenKind) {
            tokens.append(CodeToken(range: NSRange(location: start, length: index - start), kind: kind))
        }

        while index < count {
            let unit = chars[index]

            if let block = language.blockComment, matches(block.open, at: index) {
                let start = index
                index += block.open.count
                while index < count, !matches(block.close, at: index) { index += 1 }
                index = min(count, index + block.close.count)
                emit(start, .comment)
                continue
            }

            if language.lineComments.contains(where: { matches($0, at: index) }) {
                let start = index
                while index < count, !isNewline(chars[index]) { index += 1 }
                emit(start, .comment)
                continue
            }

            if language.quotes.contains(unit) {
                let start = index
                if language.tripleQuotes, matches([unit, unit, unit], at: index) {
                    index += 3
                    while index < count, !matches([unit, unit, unit], at: index) { index += 1 }
                    index = min(count, index + 3)
                } else {
                    index += 1
                    let spansLines = language.multilineQuotes.contains(unit)
                    while index < count {
                        let next = chars[index]
                        if next == backslash { index = min(count, index + 2); continue }
                        if next == unit { index += 1; break }
                        // An unterminated string stops at the end of its line, so one
                        // missing quote does not paint the rest of the file.
                        if !spansLines, isNewline(next) { break }
                        index += 1
                    }
                }
                emit(start, .string)
                continue
            }

            if language.sigils.contains(unit), index + 1 < count,
               isIdentifierStart(chars[index + 1]) || chars[index + 1] == openBrace {
                let start = index
                index += 1
                if chars[index] == openBrace {
                    // `${HOME}`: the braces are part of the reference.
                    while index < count, chars[index] != closeBrace, !isNewline(chars[index]) { index += 1 }
                    index = min(count, index + 1)
                } else {
                    while index < count, isIdentifier(chars[index]) { index += 1 }
                }
                emit(start, .attribute)
                continue
            }

            if isDigit(unit) {
                let start = index
                index += 1
                // `0xFF`, `1_000`, `3.14`, `1e-9`, `10ms`: one run of digits, letters and
                // underscores, with a dot only when a digit follows it — so `1.` before a
                // method is the number `1`.
                while index < count {
                    let next = chars[index]
                    if isIdentifier(next) { index += 1; continue }
                    if next == dot, index + 1 < count, isDigit(chars[index + 1]) { index += 1; continue }
                    if (next == minus || next == plus), index > start,
                       (chars[index - 1] == letterE || chars[index - 1] == upperE),
                       index + 1 < count, isDigit(chars[index + 1]) { index += 1; continue }
                    break
                }
                emit(start, .number)
                continue
            }

            if isIdentifierStart(unit) {
                let start = index
                while index < count, isIdentifier(chars[index]) { index += 1 }
                // Ruby's `defined?`: a keyword may end in a question mark.
                if index < count, chars[index] == question,
                   language.keywords.contains(String(decoding: chars[start...index], as: UTF16.self)) {
                    index += 1
                }
                let word = String(decoding: chars[start..<index], as: UTF16.self)
                if language.keywords.contains(word) {
                    emit(start, .keyword)
                } else if language.capitalisedTypes, isUppercase(unit) {
                    emit(start, .type)
                }
                continue
            }

            index += 1
        }
        return tokens
    }

    // MARK: Code units

    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let minus = UInt16(UInt8(ascii: "-"))
    private static let plus = UInt16(UInt8(ascii: "+"))
    private static let letterE = UInt16(UInt8(ascii: "e"))
    private static let upperE = UInt16(UInt8(ascii: "E"))
    private static let question = UInt16(UInt8(ascii: "?"))
    private static let openBrace = UInt16(UInt8(ascii: "{"))
    private static let closeBrace = UInt16(UInt8(ascii: "}"))
    private static let underscore = UInt16(UInt8(ascii: "_"))

    private static func isNewline(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }
    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    private static func isUppercase(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }
    private static func isLetter(_ unit: UInt16) -> Bool {
        isUppercase(unit) || (unit >= 97 && unit <= 122) || unit >= 0x80
    }
    private static func isIdentifierStart(_ unit: UInt16) -> Bool { isLetter(unit) || unit == underscore }
    private static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
}
