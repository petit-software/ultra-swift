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

        /// How much of the accent the focus ring carries.
        ///
        /// Named rather than inlined because it is a value that gets TUNED — the tests
        /// assert the ring is this fraction of the accent, not that it is any particular
        /// number, so trying a different weight is a one-line change instead of a one-line
        /// change plus two broken tests.
        public static let focusBorderOpacity: Double = 0.5

        /// Border of the focused pane. The focused pane must be unmistakable without
        /// relying on colour alone — pair this with the header brightness difference.
        ///
        /// Derived, not a second accent — a focus ring that disagreed with the app's tint
        /// would be the clearest possible sign the colours are not coming from one place.
        /// Held back from full strength because it outlines a whole pane rather than marking
        /// a small control: at 100% a border that long competes with the content inside it.
        /// OPAQUE, and mixed rather than faded. A translucent ring was the obvious spelling
        /// and it was wrong: the pane's border sits on the clip layer INSIDE the
        /// `NSGlassEffectView`, so a 32% ring composited over the glass rim — a near-white
        /// edge around every pane — not over the pane. The measured result was a border far
        /// stronger and lighter than the fraction asked for, and it moved with whatever the
        /// glass happened to be doing. Mixing toward the accent pins the colour to the pane
        /// instead, so the number means the same thing everywhere it is used.
        public static var focusBorder: Color {
            focusBorder(mixing: paneBackground, toward: accent)
        }

        /// The derivation itself, with BOTH inputs passed in.
        ///
        /// Split out because `paneBackground` and `accent` are live user settings that other
        /// suites mutate. A test reading ground, accent, and border as three separate
        /// statements can have the accent change underneath it between two of them, and then
        /// checks a border derived from one colour against arithmetic done on another — a
        /// flake that looks exactly like a broken ratio. With both inputs explicit there is
        /// no ambient state left for a race to touch.
        static func focusBorder(mixing ground: Color, toward accent: Color) -> Color {
            // `.device` rather than the default perceptual mix: the fraction is a knob
            // someone tunes by eye against a number, so "0.64 of the way to the accent" has
            // to be literally 0.64 of the way, not that far through a perceptual curve.
            ground.mix(with: accent, by: focusBorderOpacity, in: .device)
        }
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
