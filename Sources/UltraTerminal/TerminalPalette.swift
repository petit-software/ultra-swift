import AppKit
import SwiftTerm
import SwiftUI
import UltraDesign

/// Maps an Ultra `TerminalTheme` onto SwiftTerm's colour model.
///
/// Terminal colours are a separate system from the UI tokens (docs/02-DESIGN-LANGUAGE.md):
/// chrome follows the system appearance, terminal content follows the user's theme.
public enum TerminalPalette {

    /// SwiftTerm stores 16-bit components; SwiftUI hands us a `Color`. One conversion point,
    /// through sRGB explicitly, so a theme cannot shift depending on the display profile.
    public static func swiftTermColor(_ color: SwiftUI.Color) -> SwiftTerm.Color {
        let components = sRGBComponents(color)
        return SwiftTerm.Color(red: UInt16(components.r * 65535),
                               green: UInt16(components.g * 65535),
                               blue: UInt16(components.b * 65535))
    }

    public static func sRGBComponents(_ color: SwiftUI.Color) -> (r: Double, g: Double, b: Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(resolved.redComponent).clampedUnit,
                Double(resolved.greenComponent).clampedUnit,
                Double(resolved.blueComponent).clampedUnit)
    }

    public static func ansi(_ theme: TerminalTheme) -> [SwiftTerm.Color] {
        theme.ansi.map(swiftTermColor)
    }

    /// Apply a theme to a live terminal view. Safe to call repeatedly — switching themes
    /// must not disturb the buffer or the process.
    @MainActor
    public static func apply(_ theme: TerminalTheme, to view: TerminalView) {
        view.installColors(ansi(theme))
        view.nativeForegroundColor = NSColor(theme.foreground)
        // The theme's background RGB, at ZERO alpha — the terminal paints no default
        // background of its own, and the pane's surface shows through the cells.
        //
        // Deliberate, and the fix for a real artefact rather than a style choice. The pane
        // wrapper fills the padding around the grid and SwiftTerm filled the grid, both
        // with the same translucent colour, so the two composited and a terminal at 50%
        // opacity showed 50% in its margins and 75% behind its text. One pane, one fill:
        // `PaneContainerView.theme` owns it now, which is also what lets a Todo or a file
        // tree answer to the same slider.
        //
        // The RGB still matters and is still sent: SwiftTerm hands it to the engine as
        // `terminal.backgroundColor`, which is what reverse video and OSC 11 report.
        view.nativeBackgroundColor = NSColor(theme.background).withAlphaComponent(0)
        view.backgroundOpacity = 0
        view.caretColor = NSColor(theme.cursor)
        view.selectedTextBackgroundColor = NSColor(theme.selection)
    }
}

private extension Double {
    /// Wide-gamut conversions can land marginally outside 0…1; clamping keeps the UInt16
    /// conversion from trapping on an overflow.
    var clampedUnit: Double { Swift.min(Swift.max(self, 0), 1) }
}
