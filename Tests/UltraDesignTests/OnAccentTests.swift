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
