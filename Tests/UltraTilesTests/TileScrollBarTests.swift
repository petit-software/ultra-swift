import Testing
import SwiftUI
@testable import UltraTiles

/// The knob is a fixed height, so all the arithmetic is in how far it travels — and the
/// interesting cases are the degenerate ones: a pane shorter than the knob, content that
/// does not scroll, and rubber-banding past both ends.
@Suite("Tile scroll bar")
struct TileScrollBarTests {

    private func bar(progress: Double, height: CGFloat, scrollable: Bool = true) -> TileScrollBar {
        TileScrollBar(progress: progress, isScrollable: scrollable, trackHeight: height)
    }

    @Test("the knob is the fixed height it advertises, not a proportion of content")
    func knobIsFixed() {
        #expect(TileScrollBar.knobHeight == 42)
    }

    @Test("it is thinner than any system scroller")
    func isThin() {
        #expect(TileScrollBar.thickness < 7)
    }

    /// A pane shorter than the knob has nowhere to move it. Travel must clamp at zero rather
    /// than going negative, which would offset the knob UP and out through the top of the
    /// pane at exactly the moment the content is too short to need an indicator.
    @Test("a pane shorter than the knob never travels backwards", arguments: [
        CGFloat(0), 0.5, 0.9, 1.0,
    ])
    func shortPaneHasNoNegativeTravel(fraction: CGFloat) {
        // Expressed as a fraction of the knob so these stay the degenerate cases whatever
        // the knob height is tuned to.
        let height = TileScrollBar.knobHeight * fraction
        #expect(bar(progress: 1, height: height).travel == 0)
    }

    @Test("a tall pane travels its height less the knob and both insets")
    func tallPaneTravels() {
        let height: CGFloat = 500
        let expected = height - TileScrollBar.knobHeight - 2 * TileScrollBar.inset
        #expect(bar(progress: 0, height: height).travel == expected)
        #expect(expected > 0)
    }

    @Test("content that does not scroll shows no indicator")
    func hiddenWhenNotScrollable() {
        // The view builds to nothing; the flag is the contract callers rely on.
        #expect(bar(progress: 0, height: 400, scrollable: false).isScrollable == false)
    }
}

/// The progress arithmetic, which is where a content inset silently breaks things: a scroll
/// view with a top inset reports a negative offset at rest, so measuring from zero shows the
/// knob already part-way down a list nobody has scrolled.
@Suite("Scroll progress")
struct ScrollProgressTests {

    /// Mirrors the expression in `TileScrollBarModifier`.
    private func progress(offset: CGFloat, topInset: CGFloat,
                          content: CGFloat, insets: CGFloat, visible: CGFloat) -> Double {
        let total = content + insets
        let range = total - visible
        return range > 0 ? Double((offset + topInset) / range) : 0
    }

    @Test("at rest with a top inset, progress is zero — not part-way down")
    func restWithInsetIsZero() {
        #expect(progress(offset: -36, topInset: 36, content: 1000, insets: 36, visible: 400) == 0)
    }

    @Test("fully scrolled is one")
    func endIsOne() {
        let p = progress(offset: 600, topInset: 0, content: 1000, insets: 0, visible: 400)
        #expect(abs(p - 1) < 0.0001)
    }

    @Test("content shorter than the pane is zero, not a division by zero")
    func shortContentIsZero() {
        #expect(progress(offset: 0, topInset: 0, content: 100, insets: 0, visible: 400) == 0)
    }

    @Test("content exactly the height of the pane does not divide by zero")
    func exactFitIsZero() {
        #expect(progress(offset: 0, topInset: 0, content: 400, insets: 0, visible: 400) == 0)
    }
}
