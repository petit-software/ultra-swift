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
        public static let gutter: CGFloat = 12
        public static let dividerLine: CGFloat = 1
        public static let dividerHit: CGFloat = 16
        public static let tileHeaderHeight: CGFloat = 36
        public static let focusRingWidth: CGFloat = 2
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

        /// The window's own surface: a dark tint laid over the backdrop material at 30%,
        /// so the glass reads as smoked rather than as clear frost.
        public static let windowTintOpacity: CGFloat = 0.30
        public static let windowTint = NSColor.black

        /// The window's edge. Light in dark appearance, dark in light — it separates the
        /// window from the desktop in both directions.
        public static var windowBorder: NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.22)
                    : NSColor.black.withAlphaComponent(0.18)
            }
        }

        /// How much of the accent a held-back tint carries.
        ///
        /// One source for every muted use of the accent, so the focus ring and anything
        /// added later cannot drift into two different ideas of "quieter". Named for what it
        /// does rather than for its value — it was `accentHalf` at 0.5 for about an hour,
        /// and a token whose name states a number is a token that will eventually lie.
        public static let accentMutedStrength: Double = 0.25

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
