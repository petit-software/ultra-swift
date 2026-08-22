import SwiftUI

/// Design tokens. No literal colour or spacing value may appear outside this file.
///
/// Every colour resolves through a semantic system colour, so light, dark, Increase
/// Contrast, and accent-colour changes are automatic. See docs/02-DESIGN-LANGUAGE.md.
public enum Token {

    // MARK: Spacing — mirrors LayoutMetrics, which is the source of truth for the canvas.

    public enum Space {
        /// Wide enough that the frosted material between panes is actually visible.
        /// At 6pt the glass was there and invisible, which is the worst of both.
        /// Adjustable — see `Appearance`; the constant above is the default.
        public static var canvasPadding: CGFloat { Appearance.value(.canvasPadding) }
        public static var gutter: CGFloat { Appearance.value(.gutter) }
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
        public static let accent = Color(nsColor: .controlAccentColor)

        /// The window's own surface: a dark tint laid over the backdrop material at 30%,
        /// so the glass reads as smoked rather than as clear frost.
        public static var windowTintOpacity: CGFloat { Appearance.value(.windowTintOpacity) }
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

        /// Border of the focused pane. The focused pane must be unmistakable without
        /// relying on colour alone — pair this with the header brightness difference.
        public static let focusBorder = Color(nsColor: .controlAccentColor)
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
