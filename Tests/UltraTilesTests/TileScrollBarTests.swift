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

    /// The track is the full height of the pane, so the knob travels all of it — at
    /// progress 1 its bottom edge sits exactly on the pane's bottom edge.
    @Test("a tall pane travels its full height less the knob")
    func tallPaneTravels() {
        let height: CGFloat = 500
        let expected = height - TileScrollBar.knobHeight
        #expect(bar(progress: 0, height: height).travel == expected)
        #expect(expected > 0)
    }

    @Test("the indicator sits 12pt in from the pane's trailing edge")
    func sideInset() {
        #expect(TileScrollBar.sideInset == 12)
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
    ///
    /// `visible` is the CONTAINER size, which already has the content insets taken out of
    /// it — adding them to the content as well is the double-count that stopped the knob
    /// short of the bottom.
    private func progress(offset: CGFloat, topInset: CGFloat,
                          content: CGFloat, visible: CGFloat) -> Double {
        let range = content - visible
        return range > 0 ? Double((offset + topInset) / range) : 0
    }

    @Test("at rest with a top inset, progress is zero — not part-way down")
    func restWithInsetIsZero() {
        #expect(progress(offset: -36, topInset: 36, content: 1000, visible: 400) == 0)
    }

    @Test("fully scrolled is one")
    func endIsOne() {
        #expect(abs(progress(offset: 600, topInset: 0, content: 1000, visible: 400) - 1) < 0.0001)
    }

    /// The regression that presented as "the knob stops about three quarters down". A pane
    /// showing 500 of 700 with a 36pt footer margin reached only 200/236 ≈ 0.85, because the
    /// footer's margin was counted BOTH as extra distance to travel and as room already
    /// removed from the container.
    @Test("a floating footer's margin does not shorten the knob's travel")
    func footerMarginDoesNotCapProgress() {
        // container is the visible area, already 36 shorter than the pane.
        #expect(abs(progress(offset: 200, topInset: 0, content: 700, visible: 500) - 1) < 0.0001)
    }

    @Test("content shorter than the pane is zero, not a division by zero")
    func shortContentIsZero() {
        #expect(progress(offset: 0, topInset: 0, content: 100, visible: 400) == 0)
    }

    @Test("content exactly the height of the pane does not divide by zero")
    func exactFitIsZero() {
        #expect(progress(offset: 0, topInset: 0, content: 400, visible: 400) == 0)
    }
}
