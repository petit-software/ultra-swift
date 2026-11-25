import AppKit
import SwiftTerm
import SwiftUI
import UltraDesign

/// Keeps a pane's own text readable on the surfaces a program draws under it.
///
/// A program that paints a surface — an agent's composer, the block round a message that
/// was sent — picks a background and then writes on it in the terminal's DEFAULT
/// foreground, trusting the two to belong together. Twice over they do not:
///
/// - The background was chosen for a pane that has since changed. Codex reads the pane's
///   colours once, at launch, and never again; turn the pane light and its composer is
///   still the dark grey it mixed for the dark one, under text that is now dark too.
/// - The background is a palette colour that means something else here. Claude Code's
///   ANSI themes fill a sent message with `brightBlack`, which on a dark theme is a grey
///   a little above the background and on a light one is the dark grey of a comment.
///
/// Neither program can be told (`ColorSchemeReports` reaches only the ones that listen),
/// so the pane puts it right: a NEUTRAL background that the default foreground cannot be
/// read against is washed most of the way to the pane's own background, which leaves the
/// surface there, as a tint, and the text on it legible.
///
/// Neutral only, and that is the whole of the restraint. A red, a blue, a selection bar
/// are colours a program chose to mean something and they are left exactly as sent, however
/// they read; a grey surface means "a surface", and a tint of the pane says that as well.
public struct LegibleBackgrounds: Sendable, Equatable {

    public struct RGB: Hashable, Sendable {
        public var r, g, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        public init(r8: UInt8, g8: UInt8, b8: UInt8) {
            self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255)
        }

        /// WCAG relative luminance.
        public var luminance: Double {
            func linear(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// WCAG contrast ratio, 1…21.
        public func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// How far from grey: the spread between the largest and smallest channel.
        public var chroma: Double { max(r, g, b) - min(r, g, b) }

        public func mixed(with other: RGB, by amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount,
                b: b + (other.b - b) * amount)
        }

        var bytes: (UInt8, UInt8, UInt8) {
            func byte(_ c: Double) -> UInt8 { UInt8((min(max(c, 0), 1) * 255).rounded()) }
            return (byte(r), byte(g), byte(b))
        }
    }

    /// Below this the default foreground counts as unreadable on a background. WCAG asks
    /// 3:1 of large text and of the edge of a control; a surface that clears it is left to
    /// the program that drew it.
    public static let readable = 3.0
    /// A background this close to grey is a surface rather than a colour. Ultra's own
    /// `brightBlack` — a slate, not a true grey — is at 0.06 and 0.10.
    public static let neutral = 0.16
    /// How far a washed background goes towards the pane's own. Most of the way: what is
    /// left is the tint a composer has on a pane it was drawn for.
    public static let wash = 0.9

    public let foreground: RGB
    public let background: RGB
    private let ansi: [RGB]

    public init(theme: TerminalTheme) {
        func rgb(_ color: SwiftUI.Color) -> RGB {
            let c = TerminalPalette.sRGBComponents(color)
            return RGB(r: c.r, g: c.g, b: c.b)
        }
        foreground = rgb(theme.foreground)
        background = rgb(theme.background)
        ansi = theme.ansi.map(rgb)
    }

    /// The colour a 256-colour index is drawn in: the theme's sixteen, then xterm's cube
    /// and its grey ramp, which no theme changes.
    public func color(ansi code: UInt8) -> RGB {
        let index = Int(code)
        if index < 16 { return index < ansi.count ? ansi[index] : background }
        if index < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let cube = index - 16
            return RGB(r8: levels[cube / 36], g8: levels[(cube / 6) % 6], b8: levels[cube % 6])
        }
        let grey = UInt8(8 + 10 * (index - 232))
        return RGB(r8: grey, g8: grey, b8: grey)
    }

    /// The background to draw instead of `surface`, or nil when it is fine as it is.
    ///
    /// `text` is the cell's own foreground when the program set one, nil for the default.
    /// A cell with a colour of its own is washed along with the surface it sits on only
    /// when that does not cost it: the dim `›` at the head of a composer goes with the
    /// composer, and a light label on a dark chip — a pair the program chose together —
    /// stays the chip it was.
    public func washed(_ surface: RGB, under text: RGB? = nil) -> RGB? {
        guard surface.chroma <= Self.neutral,
              foreground.contrast(with: surface) < Self.readable else { return nil }
        let result = surface.mixed(with: background, by: Self.wash)
        if let text, text.contrast(with: result) < text.contrast(with: surface) { return nil }
        return result
    }
}

// MARK: - Applying it to a terminal's cells

/// Rewrites the cells of a SwiftTerm buffer whose background `LegibleBackgrounds` washes.
///
/// In the buffer, because that is the only place SwiftTerm lets it be done: the colour a
/// cell is drawn in is resolved inside the renderer, CoreGraphics' and Metal's both, with
/// no hook on the way. So the cell itself is changed, once, as it arrives.
@MainActor
final class BackgroundWasher {
    private var rule: LegibleBackgrounds
    /// What each attribute seen so far turns into; nil for one that is left alone. A
    /// screen is a few dozen attributes repeated thousands of times, so the rule runs
    /// once for each and the sweep is a dictionary lookup per run of cells.
    private var decisions: [Attribute: Attribute?] = [:]
    /// The first row, counted from the start of the scrollback, not yet swept.
    private var sweptThrough = 0
    private let mint = AttributeMint()

    init(theme: TerminalTheme) { rule = LegibleBackgrounds(theme: theme) }

    /// A new theme re-reads everything: what was unreadable is now fine, and the reverse.
    ///
    /// Only a theme that really is new. This is reached on every preference write, and
    /// walking the whole scrollback for a font size is a hitch for nothing.
    func themeChanged(_ theme: TerminalTheme, in terminal: Terminal) {
        let new = LegibleBackgrounds(theme: theme)
        guard new != rule else { return }
        rule = new
        decisions.removeAll(keepingCapacity: true)
        sweptThrough = 0
        sweep(terminal)
    }

    /// Wash what has arrived since the last sweep: the rows that scrolled away in the
    /// meantime, and the screen. Returns whether any cell changed.
    @discardableResult
    func sweep(_ terminal: Terminal) -> Bool {
        let top = terminal.buffer.totalLinesTrimmed
        var row = max(sweptThrough, top)
        // The alternate screen has no scrollback and counts its rows from nothing, so a
        // mark left by the normal one can be past its end. Start it over.
        if terminal.getScrollInvariantLine(row: row) == nil { row = top }
        var changed = false
        while let line = terminal.getScrollInvariantLine(row: row) {
            if wash(line) { changed = true }
            row += 1
        }
        // The screen is swept again next time — a program redraws it in place.
        sweptThrough = max(top, row - terminal.rows)
        if changed { terminal.updateFullScreen() }
        return changed
    }

    private func wash(_ line: BufferLine) -> Bool {
        var changed = false
        var last: Attribute?
        var lastDecision: Attribute?
        for column in 0..<line.count {
            var cell = line[column]
            let attribute = cell.attribute
            // The overwhelmingly common cell, decided without a lookup.
            if attribute.bg == .defaultColor || attribute.bg == .defaultInvertedColor { continue }
            if attribute != last {
                last = attribute
                lastDecision = decision(for: attribute)
            }
            guard let replacement = lastDecision else { continue }
            cell.attribute = replacement
            line[column] = cell
            changed = true
        }
        return changed
    }

    private func decision(for attribute: Attribute) -> Attribute? {
        if let known = decisions[attribute] { return known }
        let made = decide(attribute)
        decisions[attribute] = .some(made)
        return made
    }

    private func decide(_ attribute: Attribute) -> Attribute? {
        // Reverse video draws the foreground as the background: a different surface, and
        // one made of the pane's own two colours, which always read.
        guard !attribute.style.contains(.inverse),
              let surface = color(attribute.bg) else { return nil }
        let text = attribute.fg == .defaultColor ? nil : color(attribute.fg)
        if attribute.fg != .defaultColor, text == nil { return nil }
        guard let washed = rule.washed(surface, under: text) else { return nil }
        return mint.attribute(like: attribute, background: washed)
    }

    private func color(_ color: Attribute.Color) -> LegibleBackgrounds.RGB? {
        switch color {
        case .ansi256(let code): return rule.color(ansi: code)
        case .trueColor(let r, let g, let b): return .init(r8: r, g8: g, b8: b)
        case .defaultColor, .defaultInvertedColor: return nil
        }
    }
}

/// Makes an `Attribute` with a background of our choosing.
///
/// SwiftTerm's `Attribute` can be read from outside the package and not built: its
/// initialiser is internal and its fields are set-private. What CAN make one is a
/// terminal, from SGR. So a second, headless terminal that nothing is ever shown from is
/// asked for the attribute by being sent the sequence that describes it, and the cell it
/// writes is read back. Checked against the original afterwards: an attribute this cannot
/// reproduce exactly is one that is left alone, not one that loses its underline.
@MainActor
private final class AttributeMint {
    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let delegate = Silent()
    private lazy var terminal = Terminal(delegate: delegate,
                                         options: TerminalOptions(cols: 4, rows: 2))

    func attribute(like original: Attribute, background: LegibleBackgrounds.RGB) -> Attribute? {
        var codes = ["0"]
        let styles: [(CharacterStyle, String)] = [
            (.bold, "1"), (.dim, "2"), (.italic, "3"), (.blink, "5"),
            (.invisible, "8"), (.crossedOut, "9"),
        ]
        for (style, code) in styles where original.style.contains(style) { codes.append(code) }
        switch original.underlineStyle {
        case .none: break
        case .single: codes.append("4")
        case .double: codes.append("4:2")
        case .curly: codes.append("4:3")
        case .dotted: codes.append("4:4")
        case .dashed: codes.append("4:5")
        }
        switch original.fg {
        case .ansi256(let code): codes.append("38;5;\(code)")
        case .trueColor(let r, let g, let b): codes.append("38;2;\(r);\(g);\(b)")
        case .defaultColor, .defaultInvertedColor: break
        }
        switch original.underlineColor {
        case .ansi256(let code)?: codes.append("58;5;\(code)")
        case .trueColor(let r, let g, let b)?: codes.append("58;2;\(r);\(g);\(b)")
        default: break
        }
        let (r, g, b) = background.bytes
        codes.append("48;2;\(r);\(g);\(b)")
        terminal.feed(text: "\u{1b}[H\u{1b}[\(codes.joined(separator: ";"))mx")
        guard let made = terminal.getLine(row: 0)?[0].attribute,
              made.bg == .trueColor(red: r, green: g, blue: b),
              made.fg == original.fg, made.style == original.style,
              made.underlineStyle == original.underlineStyle,
              made.underlineColor == original.underlineColor else { return nil }
        return made
    }
}
