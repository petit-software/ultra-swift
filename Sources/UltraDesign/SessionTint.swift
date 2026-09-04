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
/// a second app; a few dozen that answer "what kind of project is this" is a decision
/// someone can make in a second and recognise a week later.
///
/// Ordered in ROWS of `columns`, each row one theme — panes and code, build and debug,
/// machines, data, network, security, people, business, media, documents, nature, marks.
/// The grid is laid out row-wise, so the order here IS the grouping the user reads; adding
/// a symbol means putting it in its row, not on the end. A test keeps the count a whole
/// number of rows, because a half-filled last row is a ragged edge under a tidy grid.
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

    /// How wide the picker's grid is, and therefore how long a themed row of this list is.
    /// One number, read by both the catalogue's tests and the picker, so the rows a reader
    /// sees are the rows written here.
    public static let columns = 6

    /// Nothing is ever REMOVED from this list, only added to it. A name that leaves the
    /// catalogue stops resolving — see `resolved` — so every session that had chosen it
    /// silently goes back to the default mark.
    public static let all: [String] = [
        // Panes, files, code
        "square.split.2x1.fill", "folder.fill", "apple.terminal.fill", "curlybraces.square.fill",
        "app.fill", "square.stack.3d.up.fill",
        // Build, debug, ideas
        "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill",
        "puzzlepiece.extension.fill", "ladybug.fill", "lightbulb.fill",
        // Machines and packages
        "cpu.fill", "memorychip.fill", "keyboard.fill", "externaldrive.fill",
        "cube.fill", "shippingbox.fill",
        // Data, models, science
        "cylinder.split.1x2.fill", "tablecells.fill", "chart.bar.fill", "brain.fill",
        "flask.fill", "waveform.circle.fill",
        // Network and power
        "cloud.fill", "globe.americas.fill", "antenna.radiowaves.left.and.right.circle.fill",
        "circle.hexagongrid.fill", "bolt.fill", "flame.fill",
        // Security and trust
        "lock.fill", "key.fill", "shield.fill", "eye.fill",
        "checkmark.seal.fill", "lifepreserver.fill",
        // People and messages
        "envelope.fill", "message.fill", "bell.fill", "phone.fill",
        "person.2.fill", "quote.bubble.fill",
        // Business and money
        "briefcase.fill", "building.2.fill", "house.fill", "cart.fill",
        "creditcard.fill", "dollarsign.circle.fill",
        // Media and play
        "camera.fill", "photo.fill", "movieclapper.fill", "gamecontroller.fill",
        "paintbrush.fill", "theatermasks.fill",
        // Documents and reading
        "doc.text.fill", "book.fill", "newspaper.fill", "tray.fill",
        "archivebox.fill", "graduationcap.fill",
        // Outdoors and weather
        "leaf.fill", "tree.fill", "mountain.2.fill", "drop.fill",
        "sun.max.fill", "moon.fill",
        // Marks
        "star.fill", "heart.fill", "bookmark.fill", "tag.fill",
        "flag.fill", "trophy.fill",
        // Windows and stacks
        "rectangle.on.rectangle.fill", "rectangle.split.3x3.fill", "square.grid.2x2.fill",
        "rectangle.3.group.fill", "square.stack.fill", "square.fill.on.square.fill",
        // Code and documents
        "terminal.fill", "text.page.fill", "doc.on.doc.fill", "doc.badge.gearshape.fill",
        "list.bullet.rectangle.fill", "list.clipboard.fill",
        // Servers and cloud
        "cloud.bolt.fill", "icloud.fill", "externaldrive.connected.to.line.below.fill",
        "wifi.circle.fill", "powerplug.fill", "bolt.horizontal.fill",
        // Places
        "globe.europe.africa.fill", "globe.asia.australia.fill", "map.fill",
        "location.fill", "mappin.circle.fill", "safari.fill",
        // Devices
        "tv.fill", "appletv.fill", "homepod.fill", "hifispeaker.fill",
        "printer.fill", "scanner.fill",
        // Health and science
        "brain.head.profile.fill", "waveform.path.ecg.rectangle.fill", "cross.case.fill",
        "pills.fill", "syringe.fill", "bandage.fill",
        // Commerce
        "banknote.fill", "wallet.pass.fill", "bag.fill", "storefront.fill",
        "gift.fill", "ticket.fill",
        // People and time
        "person.fill", "person.3.fill", "person.crop.circle.fill", "clock.fill",
        "calendar.circle.fill", "stopwatch.fill",
        // Home and hospitality
        "building.fill", "building.columns.fill", "sofa.fill", "lamp.desk.fill",
        "cup.and.saucer.fill", "birthday.cake.fill",
        // Media and craft
        "mic.fill", "radio.fill", "film.fill", "video.fill",
        "paintpalette.fill", "guitars.fill",
        // Status
        "checkmark.circle.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill",
        "xmark.octagon.fill", "medal.fill", "crown.fill",
        // Messages and security
        "text.bubble.fill", "bell.badge.fill", "envelope.badge.fill", "lock.shield.fill",
        "key.horizontal.fill", "checkmark.shield.fill",
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
