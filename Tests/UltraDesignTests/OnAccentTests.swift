import Testing
import AppKit
@testable import UltraDesign

/// A label on a solid accent fill has to be picked, never assumed.
///
/// This app's accent is user-chosen and its DEFAULT is `.white`, so the ordinary "fill with
/// the accent, write the label in white" pairing produces a white control with a white word
/// on it — which is how the new-project sheet shipped for about ten minutes.
@Suite("Label on an accent fill")
struct OnAccentTests {

    @Test("a light fill takes a dark label", arguments: [
        NSColor.white, .systemYellow, .systemMint, .systemTeal,
    ])
    func lightFillsTakeBlack(fill: NSColor) {
        #expect(Token.Colour.onAccentColour(fill) == .black)
    }

    @Test("a dark or saturated fill takes a light label", arguments: [
        NSColor.black, .systemBlue, .systemPurple, .systemRed, .systemIndigo,
    ])
    func darkFillsTakeWhite(fill: NSColor) {
        #expect(Token.Colour.onAccentColour(fill) == .white)
    }

    /// Green is the case an unweighted average gets wrong in the other direction: the eye is
    /// far more sensitive to green than to blue, so a mid green is genuinely light.
    @Test("weighting is by perceived brightness, not by an average of the channels")
    func greenIsTreatedAsLight() {
        #expect(Token.Colour.onAccentColour(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
                == .black)
        #expect(Token.Colour.onAccentColour(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
                == .white,
                "the same channel value in blue is dark, which an average cannot tell apart")
    }

    /// A colour with no RGB representation must still produce a readable label rather than
    /// falling through to whatever the caller had.
    @Test("a colour that cannot be converted still answers")
    func unconvertibleStillAnswers() {
        let answer = Token.Colour.onAccentColour(.textColor)
        #expect(answer == .white || answer == .black)
    }
}

/// The washes behind a tinted thing — the chat's user bubble, a selected row, a notice bar —
/// are the accent at a low alpha, and the default accent is white. White at 14% on a light
/// pane is the pane, so with that one accent the wash has to invert with the appearance.
@Suite("Accent wash in both appearances")
struct AccentWashTests {

    private func resolved(_ colour: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        var out = NSColor.clear
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            out = colour.usingColorSpace(.sRGB)!
        }
        return out
    }

    @Test("the white accent's wash is white on dark and black on light")
    func whiteWashInverts() {
        let dark = resolved(Token.Colour.whiteWashColour(0.14), in: .darkAqua)
        #expect(dark.redComponent == 1 && dark.alphaComponent == 0.14)

        let light = resolved(Token.Colour.whiteWashColour(0.14), in: .aqua)
        #expect(light.redComponent == 0 && light.greenComponent == 0 && light.blueComponent == 0,
                "translucent white on a white pane is nothing; the light wash must be dark")
        #expect(light.alphaComponent > 0.05 && light.alphaComponent < 0.14,
                "dark-on-light needs less of itself to read as the same wash")
    }

    @Test("the strong wash stays stronger in both appearances")
    func strongStaysStronger() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            #expect(resolved(Token.Colour.whiteWashColour(0.24), in: appearance).alphaComponent
                    > resolved(Token.Colour.whiteWashColour(0.14), in: appearance).alphaComponent)
        }
    }

    @Test("a coloured accent's wash is that colour, untouched by the appearance")
    func colouredWashIsTheAccent() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let wash = resolved(NSColor(Token.Colour.wash(0.14, accent: .red)), in: appearance)
            #expect(wash.redComponent > 0.5 && wash.blueComponent < 0.5)
            #expect(abs(wash.alphaComponent - 0.14) < 0.01)
        }
    }

    @Test("the wash picks the dynamic colour only for the white accent")
    func onlyWhiteIsDynamic() {
        let white = resolved(NSColor(Token.Colour.wash(0.14, accent: .white)), in: .aqua)
        #expect(white.redComponent < 0.01, "white accent, light pane: a dark veil")
        let blue = resolved(NSColor(Token.Colour.wash(0.14, accent: .blue)), in: .aqua)
        #expect(blue.blueComponent > blue.redComponent, "blue accent: still blue")
    }
}
