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
        public static let canvasPadding: CGFloat = 12
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
        public static let accent = Color(nsColor: .controlAccentColor)

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

        // MARK: Drop-preview reflow

        /// How long panes take to slide aside when a drop target changes.
        ///
        /// Long enough to read as *moving*, short enough that a drag across three panes
        /// does not feel like wading. Zero under Reduce Motion, where the panes jump.
        public static var reflowDuration: CFTimeInterval {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
        }

        /// Decelerating cubic bezier. Panes commit to the move immediately and settle into
        /// it — an ease-in-out would make them look hesitant about where they are going.
        public static var reflowCurve: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        }

        /// The grab / release micro-interaction on the pane being dragged.
        public static let grabDuration: CFTimeInterval = 0.18
    }

    // MARK: Drag

    public enum Drag {
        /// What is left behind at the source: a phantom, not a hole. Keeping the pane
        /// visible-but-faded is what makes the reflow legible — you can see the thing you
        /// are moving and the space it came from at the same time.
        public static let phantomOpacity: CGFloat = 0.38
        /// The dragged preview lifts slightly. Scale lives on the PREVIEW, never on the
        /// source pane: scaling a frame-laid-out AppKit view fights the layout pass.
        public static let liftScale: CGFloat = 1.03
        public static let previewOpacity: CGFloat = 0.92
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
