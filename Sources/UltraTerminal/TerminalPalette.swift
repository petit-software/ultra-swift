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
        // Alpha-bearing background: SwiftTerm renders the default background translucently
        // and leaves text, caret, selection and explicitly-coloured cells opaque. At 0 the
        // terminal paints no background at all and the pane's glass shows through.
        view.nativeBackgroundColor = NSColor(theme.background)
            .withAlphaComponent(theme.backgroundOpacity)
        view.backgroundOpacity = theme.backgroundOpacity
        view.caretColor = NSColor(theme.cursor)
        view.selectedTextBackgroundColor = NSColor(theme.selection)
    }
}

private extension Double {
    /// Wide-gamut conversions can land marginally outside 0…1; clamping keeps the UInt16
    /// conversion from trapping on an overflow.
    var clampedUnit: Double { Swift.min(Swift.max(self, 0), 1) }
}
