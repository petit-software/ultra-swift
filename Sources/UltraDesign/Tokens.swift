import AppKit
import SwiftUI

/// Design tokens. No literal colour or spacing value may appear outside this file.
///
/// Every colour resolves through a semantic system colour, so light, dark, Increase
/// Contrast, and accent-colour changes are automatic. See docs/02-DESIGN-LANGUAGE.md.
public enum Token {

    // MARK: Spacing — mirrors LayoutMetrics, which is the source of truth for the canvas.

    public enum Space {
        /// Mirrors `LayoutMetrics.padding`. The canvas's real outer inset is this plus
        /// `edgeInset`, which is 12pt — the note below is about the GUTTER between panes,
        /// where the material has to read, not about the window's outer edges, where there
        /// is nothing between the pane and the window to make visible.
        ///
        /// Wide enough that the frosted material between panes is actually visible.
        /// At 6pt the glass was there and invisible, which is the worst of both.
        public static let canvasPadding: CGFloat = 8
        /// Now a setting — see `Appearance.paneGutter`. The default is still 12.
        public static var gutter: CGFloat { Appearance.paneGutter }
        public static let dividerLine: CGFloat = 1
        public static let dividerHit: CGFloat = 16
        public static let tileHeaderHeight: CGFloat = 36
        public static var focusRingWidth: CGFloat { Appearance.focusRingWidth }
        /// How far in from the pane's edge the ring sits. ZERO — flush.
        ///
        /// It was 1.5 while the ring appeared at full strength no matter what alpha it
        /// carried, on the theory that it was compositing over a near-white glass rim. The
        /// inset did fix it, but it left a visible sliver of pane outside the ring, and the
        /// rim measures (55,54,50) now — dark enough that flush costs nothing. Measured both
        /// ways: 53–54% of the way from the pane to a full accent either side of the change.
        public static let focusRingInset: CGFloat = 0
        /// How far the traffic lights sit from the window's leading edge. AppKit's default
        /// puts them tight into the corner; with a 24pt-tall bar and a rounded window they
        /// want more room to breathe.
        public static let trafficLightInset: CGFloat = 30
        /// Centre-to-centre spacing of the three buttons. The system value.
        public static let trafficLightSpacing: CGFloat = 20
        public static let tileBodyInset: CGFloat = 10
        public static let rowSpacing: CGFloat = 4
    }

    // MARK: Colour

    public enum Colour {
        /// Pane body. Opaque — terminal text never sits on a modulating backdrop.
        public static let paneBackground = Color(nsColor: .textBackgroundColor)
        public static let tileBackground = Color(nsColor: .controlBackgroundColor)
        public static let separator = Color(nsColor: .separatorColor)
        public static let label = Color(nsColor: .labelColor)
        public static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        public static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
        /// The single tint. Every variation below is derived from it, so one setting moves
        /// all of them — see `Preferences.AccentColour`.
        public static var accent: Color { Preferences.accentColour.color }

        /// A soft fill behind something tinted: a selected row, a notice bar, a highlight.
        /// One value rather than the 0.10 / 0.12 / 0.18 / 0.20 that had accumulated across
        /// the tiles, all of them meaning "a bit of the accent behind this".
        public static var accentWash: Color { accent.opacity(0.14) }

        /// The same idea, but for something the pointer is actively over — a drop target.
        public static var accentWashStrong: Color { accent.opacity(0.24) }

        /// The window's own surface: a tint laid over the backdrop material so the glass
        /// reads as smoked rather than as clear frost.
        ///
        /// DYNAMIC, and that is the whole point. It was `NSColor.black` at 30% flat, which
        /// is right in dark appearance and simply wrong in light: the light theme's own
        /// surface sat under a third of a black veil, so Light mode was a dimmer dark mode
        /// rather than a light one. Light appearance lifts instead of darkens.
        ///
        /// The alpha is carried IN the colour rather than applied by the call site, so the
        /// two appearances can want different amounts of it — and they do; white needs more
        /// to read as a surface than black needs to read as smoke.
        public static var windowTint: NSColor {
            // Both amounts are read INSIDE the resolver, so a change to either reaches a
            // colour that has already been handed out.
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.black.withAlphaComponent(Appearance.windowTintDark)
                    : NSColor.white.withAlphaComponent(Appearance.windowTintLight)
            }
        }

        /// What a pane header's ramp darkens — or lightens — with. Same reasoning as
        /// `windowTint`: a black veil under a title is separation in dark appearance and a
        /// smudge in light one.
        public static var headerTint: NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.black
                    : NSColor.white
            }
        }

        /// The wash behind a selected row in the session sidebar.
        ///
        /// A neutral veil rather than the accent. A list whose selection is a saturated
        /// accent block fights the row's own colour: the session icon is user-chosen and can
        /// be any of twelve hues, and half of them are unreadable sitting on a slab of a
        /// thirteenth. Translucent white leaves the icon and the name as the only colour in
        /// the row and lets the window's material show through.
        ///
        /// It inverts in light appearance for the obvious reason — translucent white on a
        /// light sidebar is not a selection, it is nothing — and takes a little less of
        /// itself there, the same correction `windowBorder` makes.
        public static let sidebarSelection = Color(nsColor:
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.16)
                    : NSColor.black.withAlphaComponent(0.10)
            }
        )

        /// The window's edge. Light in dark appearance, dark in light — it separates the
        /// window from the desktop in both directions.
        public static var windowBorder: NSColor {
            NSColor(name: nil) { appearance in
                let strength = Appearance.windowBorderStrength
                return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(strength)
                    // Dark-on-light needs a little less of itself to read as the same edge.
                    : NSColor.black.withAlphaComponent(strength * 0.82)
            }
        }

        /// How much of the accent a held-back tint carries.
        ///
        /// One source for every muted use of the accent, so the focus ring and anything
        /// added later cannot drift into two different ideas of "quieter". Named for what it
        /// does rather than for its value — it was `accentHalf` at 0.5 for about an hour,
        /// and a token whose name states a number is a token that will eventually lie.
        public static var accentMutedStrength: Double { Double(Appearance.focusRingStrength) }

        /// The accent, held back. TRANSLUCENT on purpose.
        ///
        /// An opaque mix toward the accent was tried and reads wrong: a colour blended part
        /// of the way toward a saturated blue is still plainly blue, only darker, so the
        /// number and what the eye sees disagree. Alpha lets the pane show through, which is
        /// what "less" actually looks like.
        public static var accentMuted: Color { accent.opacity(accentMutedStrength) }

        /// The focused pane's ring — the accent, held back.
        public static var focusBorder: Color { accentMuted }

        public static let unfocusedBorder = Color(nsColor: .separatorColor)

        // MARK: Agent status
        //
        // The four states a session row can report — see `AgentStatus`. System colours
        // rather than hand-picked hues, for the reason `SessionTint` gives: they are legible
        // in both appearances and follow Increase Contrast without this app tracking it.
        //
        // Deliberately NOT the accent, even for `agentWorking`, which is the one that would
        // read naturally as "the app's own colour". The accent is user-chosen and can be any
        // of twelve hues, including the green and the red these have to be told apart from —
        // a status vocabulary that changes meaning with a preference is not a vocabulary.
        public static let agentWorking = Color(nsColor: .systemBlue)
        public static let agentNeedsInput = Color(nsColor: .systemYellow)
        public static let agentDone = Color(nsColor: .systemGreen)
        public static let agentFailed = Color(nsColor: .systemRed)

        /// Divider hairline. Under Increase Contrast this becomes an opaque separator.
        public static var divider: Color {
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? Color(nsColor: .separatorColor)
                : Color(nsColor: .separatorColor).opacity(0.6)
        }
    }

    // MARK: Type

    public enum Type_ {
        public static let tileTitle = Font.system(size: 15, weight: .medium)
        public static let tileSubtitle = Font.system(size: 15, weight: .regular)
        public static let body = Font.system(size: 13)
        public static let monoSmall = Font.system(size: 11, design: .monospaced)
    }

    // MARK: Motion

    public enum Motion {
        /// Structural change: split, close, zoom. Nothing animates during a divider drag.
        public static let structural = Animation.spring(duration: 0.18, bounce: 0.1)

        /// Honour Reduce Motion at the call site rather than hoping the system does it.
        public static var structuralRespectingPreferences: Animation? {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : structural
        }

    }


    // MARK: Environment

    public enum Environment_ {
        public static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        public static var reduceTransparency: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        public static var increaseContrast: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }
}
