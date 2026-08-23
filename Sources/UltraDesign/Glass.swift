import SwiftUI

/// Liquid Glass, applied only where it belongs.
///
/// Glass is the material of the NAVIGATION layer — bars, headers, floating controls.
/// Never the content layer, and in this app the content layer is terminal text.
/// See docs/02-DESIGN-LANGUAGE.md for the two reasons that is not negotiable.
public extension View {

    /// Chrome that floats above content: tile headers, palette, HUDs, drop-zone overlays.
    ///
    /// Falls back to an opaque surface under Reduce Transparency, which is treated as a
    /// first-class appearance rather than a degraded one.
    @ViewBuilder
    func ultraChromeGlass(tinted: Bool = false) -> some View {
        if Token.Environment_.reduceTransparency {
            background(Token.Colour.tileBackground)
        } else if tinted {
            glassEffect(.regular.tint(Token.Colour.accent), in: ConcentricRectangle())
        } else {
            glassEffect(.regular, in: ConcentricRectangle())
        }
    }

    /// An interactive glass control — scales and shimmers on hover/press.
    /// Only ever applied to a PRIMARY action; when everything is tinted, nothing stands out.
    @ViewBuilder
    func ultraGlassControl() -> some View {
        if Token.Environment_.reduceTransparency {
            background(Token.Colour.tileBackground, in: .capsule)
        } else {
            glassEffect(.regular.interactive(), in: .capsule)
        }
    }

}
