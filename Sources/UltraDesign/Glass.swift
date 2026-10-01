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

    /// A toast floating over a tile's content: regular glass in a capsule, never tinted.
    ///
    /// Not `ultraGlassControl`: that one is interactive, and a toast is not a button — it
    /// holds buttons. Under Reduce Transparency the capsule goes solid and takes a hairline,
    /// since without the glass's own rim nothing would separate it from the content.
    @ViewBuilder
    func ultraToastGlass() -> some View {
        if Token.Environment_.reduceTransparency {
            background(Token.Colour.tileBackground, in: .capsule)
                .overlay(Capsule().strokeBorder(Token.Colour.separator, lineWidth: 1))
        } else {
            glassEffect(.regular, in: .capsule)
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
