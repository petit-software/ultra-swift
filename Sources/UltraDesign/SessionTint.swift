import AppKit
import SwiftUI

/// The colours a session's sidebar icon can be.
///
/// A fixed, named palette rather than a colour well. A well lets a user pick 4% grey on a
/// dark sidebar and lose the row; these are all system colours, so every one of them is
/// legible in light and dark and shifts with the system's accent and increase-contrast
/// settings without this app tracking any of that.
///
/// The raw values are what `SessionAppearance` writes to disk, so they are API: renaming a
/// case silently resets everyone who chose it.
public enum SessionTint: String, CaseIterable, Identifiable, Sendable {
    case accent, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray

    public var id: String { rawValue }

    /// Unknown raw values resolve to the accent — a palette that loses a colour in a later
    /// version must not leave a row with no colour at all.
    public init(storedValue: String) {
        self = SessionTint(rawValue: storedValue) ?? .accent
    }

    public var color: Color {
        switch self {
        // Not a fixed hue: the user's own accent, which is what an uncustomised row has
        // always been drawn in.
        case .accent: return Token.Colour.accent
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .mint: return Color(nsColor: .systemMint)
        case .teal: return Color(nsColor: .systemTeal)
        case .blue: return Color(nsColor: .systemBlue)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .gray: return Color(nsColor: .systemGray)
        }
    }

    /// For the picker's accessibility label and its tooltip. A swatch with no name is
    /// unreachable to VoiceOver and unnameable to anyone describing it.
    public var title: String {
        switch self {
        case .accent: return "Accent"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .mint: return "Mint"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .gray: return "Graphite"
        }
    }
}

/// The symbols a session's sidebar icon can be.
///
/// A curated list, not the whole SF Symbols library. 7,000 symbols behind a search field is
/// a second app; two dozen that answer "what kind of project is this" is a decision someone
/// can make in a second and recognise a week later.
///
/// Every one is a `.fill` variant, and that is the point of curating rather than opening the
/// library: at 15pt in a sidebar an outline symbol is a few hairlines of colour and reads as
/// a smudge, while a filled one carries its tint as a solid shape you can tell apart across
/// the room. A symbol with no fill variant is simply not offered — several obvious
/// candidates (`network`, `sparkles`, `server.rack`) were dropped for exactly that reason
/// rather than mixing weights in one grid.
///
/// Both rules are checked by tests. An SF Symbol name that does not exist on the running
/// system renders as NOTHING at all — a blank row, with no error anywhere to explain it.
public enum SessionSymbols {
    /// What a session wears until someone chooses otherwise, and what an unrecognised
    /// stored name falls back to.
    public static let fallback = "square.split.2x1.fill"

    public static let all: [String] = [
        "square.split.2x1.fill", "folder.fill", "apple.terminal.fill", "curlybraces.square.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "cpu.fill",
        "cube.fill", "shippingbox.fill", "externaldrive.fill", "cloud.fill",
        "globe.americas.fill", "lock.fill", "bolt.fill", "flame.fill",
        "leaf.fill", "flask.fill", "paintbrush.fill", "book.fill",
        "doc.text.fill", "star.fill", "heart.fill", "bookmark.fill",
    ]

    /// Does this system have the symbol? Used by the test that guards the catalogue.
    public static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The symbol to actually draw for a stored name.
    ///
    /// Membership of the catalogue, not just resolvability. A name saved by an older build
    /// can still be a real symbol — an unfilled `folder`, say — and drawing it would put the
    /// one outline glyph in a sidebar of filled ones. Anything not on the current list goes
    /// back to the default, which is a visible, explicable result rather than a mixed list.
    public static func resolved(_ name: String) -> String {
        all.contains(name) && exists(name) ? name : fallback
    }
}
