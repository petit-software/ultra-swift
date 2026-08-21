import SwiftUI

/// Terminal colours are a SEPARATE system from the UI tokens.
///
/// Chrome follows the system appearance; terminal content follows the user's theme, and
/// the two must never be conflated — overriding someone's terminal palette for "design"
/// reasons is the fastest way to make a terminal feel wrong.
public struct TerminalTheme: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isDark: Bool

    /// Only used when `backgroundOpacity` is above 0. The panes are glass, so by default
    /// the terminal paints no background at all and the material shows through the cells.
    public var background: Color
    /// Opacity of the terminal's DEFAULT background only. Text, the caret, selections and
    /// cells with explicit colours stay fully opaque at any value.
    public var backgroundOpacity: CGFloat = 0
    public var foreground: Color
    public var dimForeground: Color
    public var cursor: Color
    public var selection: Color
    /// 16 ANSI colours: 8 normal, then 8 bright.
    public var ansi: [Color]

    public init(id: String, name: String, isDark: Bool, background: Color,
                backgroundOpacity: CGFloat = 0, foreground: Color,
                dimForeground: Color, cursor: Color, selection: Color, ansi: [Color]) {
        precondition(ansi.count == 16, "an ANSI palette is exactly 16 colours")
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = background
        self.backgroundOpacity = backgroundOpacity
        self.foreground = foreground
        self.dimForeground = dimForeground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }

    public var green: Color { ansi[2] }
    public var yellow: Color { ansi[3] }
    public var blue: Color { ansi[4] }
    public var magenta: Color { ansi[5] }
    public var cyan: Color { ansi[6] }
    public var brightBlack: Color { ansi[8] }

    /// Both defaults clear 4.5:1 for normal text against their own background.
    public static let dark = TerminalTheme(
        id: "ultra.dark", name: "Ultra Dark", isDark: true,
        background: Color(red: 0.055, green: 0.067, blue: 0.086),
        backgroundOpacity: 0,
        foreground: Color(red: 0.804, green: 0.835, blue: 0.878),
        dimForeground: Color(red: 0.478, green: 0.525, blue: 0.588),
        cursor: Color(red: 0.353, green: 0.784, blue: 0.980),
        selection: Color(red: 0.196, green: 0.290, blue: 0.427),
        ansi: [
            Color(red: 0.180, green: 0.204, blue: 0.251), Color(red: 0.937, green: 0.400, blue: 0.435),
            Color(red: 0.427, green: 0.812, blue: 0.522), Color(red: 0.898, green: 0.729, blue: 0.404),
            Color(red: 0.353, green: 0.647, blue: 0.949), Color(red: 0.769, green: 0.545, blue: 0.949),
            Color(red: 0.318, green: 0.784, blue: 0.824), Color(red: 0.706, green: 0.741, blue: 0.796),
            Color(red: 0.290, green: 0.325, blue: 0.388), Color(red: 0.976, green: 0.522, blue: 0.549),
            Color(red: 0.545, green: 0.882, blue: 0.624), Color(red: 0.965, green: 0.808, blue: 0.502),
            Color(red: 0.478, green: 0.729, blue: 0.980), Color(red: 0.855, green: 0.651, blue: 0.980),
            Color(red: 0.427, green: 0.867, blue: 0.902), Color(red: 0.882, green: 0.906, blue: 0.937),
        ])

    public static let light = TerminalTheme(
        id: "ultra.light", name: "Ultra Light", isDark: false,
        background: Color(red: 0.992, green: 0.992, blue: 0.988),
        backgroundOpacity: 0,
        foreground: Color(red: 0.145, green: 0.161, blue: 0.188),
        dimForeground: Color(red: 0.427, green: 0.451, blue: 0.486),
        cursor: Color(red: 0.098, green: 0.451, blue: 0.769),
        selection: Color(red: 0.796, green: 0.867, blue: 0.965),
        ansi: [
            Color(red: 0.220, green: 0.239, blue: 0.271), Color(red: 0.769, green: 0.196, blue: 0.235),
            Color(red: 0.153, green: 0.518, blue: 0.278), Color(red: 0.616, green: 0.435, blue: 0.078),
            Color(red: 0.098, green: 0.435, blue: 0.769), Color(red: 0.502, green: 0.267, blue: 0.702),
            Color(red: 0.078, green: 0.471, blue: 0.502), Color(red: 0.427, green: 0.451, blue: 0.486),
            Color(red: 0.353, green: 0.376, blue: 0.408), Color(red: 0.847, green: 0.267, blue: 0.302),
            Color(red: 0.180, green: 0.580, blue: 0.318), Color(red: 0.686, green: 0.502, blue: 0.106),
            Color(red: 0.145, green: 0.494, blue: 0.831), Color(red: 0.573, green: 0.322, blue: 0.769),
            Color(red: 0.106, green: 0.533, blue: 0.569), Color(red: 0.176, green: 0.196, blue: 0.224),
        ])

    public static func matchingAppearance(_ isDark: Bool) -> TerminalTheme { isDark ? .dark : .light }
}

extension Token.Space {
    /// AppKit's corner radius for a titled window, measured at 15.5pt on macOS 26.
    ///
    /// It is not ours to choose: the system masks a titled window to this value and offers
    /// no API to change it. Drawing our own rounded surface inside that mask produced two
    /// concentric arcs at every corner. Escaping the mask requires an untitled window, and
    /// an untitled window cannot become key — no keystroke would ever reach a shell.
    /// So the window wears the system's corner, and we draw no second one.
    public static let systemWindowRadius: CGFloat = 15.5

    /// The window's visible corner radius.
    ///
    /// MUST be >= `systemWindowRadius`. That constraint is the whole trick: AppKit masks a
    /// titled window to 15.5pt, so a *larger* radius is strictly inside the mask and draws
    /// cleanly — the system arc is never reached and never shows. A *smaller* radius pokes
    /// outside the mask, which is what produced the two-concentric-arcs glitch this file
    /// used to warn about. Increasing is safe; decreasing below 15.5 is not.
    public static let windowRadius: CGFloat = 24

    /// The window's edge stroke. Thicker than a hairline so the window still has a defined
    /// boundary once its surface is dark glass over an arbitrary desktop.
    public static let windowBorderWidth: CGFloat = 1.5

    /// Pane corner radius. Deliberately NOT `systemWindowRadius - canvasPadding` (which
    /// would be 3.5pt and look mean): with a 12pt gutter the panes are visually separate
    /// surfaces floating on the material, not nested containers, so strict concentricity
    /// does not apply and a generous radius does more for the look.
    public static let paneRadius: CGFloat = 18
    /// Matches the AppKit titlebar of a `.titled` window, so the window bar sits exactly
    /// in the transparent titlebar and the panes below it never collide with it.
    /// Matches a `.unified` NSToolbar titlebar. The toolbar is what makes AppKit lay the
    /// traffic lights out the way Finder does — lower and further in — so this height must
    /// track it or the window bar and the buttons disagree.
    public static let titleBarHeight: CGFloat = 52

    /// How far a pane lifts off the material behind it. Depth, not borders, is what makes
    /// a grid of panes read as separate surfaces rather than as drawn rectangles.
    public static let paneShadowRadius: CGFloat = 10
    public static let paneShadowOpacity: Float = 0.28
}

extension Token.Type_ {
    /// The terminal grid follows the user's font setting, never Dynamic Type.
    public static func terminal(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}
