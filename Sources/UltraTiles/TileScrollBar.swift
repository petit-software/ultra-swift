import SwiftUI
import UltraDesign

/// A pane's own scroll indicator: thin, short, and drawn by us.
///
/// The system's is not usable here. With "Show scroll bars: Always" — the default the moment
/// a mouse is attached — macOS switches every scroller to `.legacy`, which RESERVES width
/// rather than overlaying it, putting a permanent grey gutter down the inside of every pane.
/// Panes here are narrow by design. `ShellTerminalView` has pinned its scroller to `.overlay`
/// and hidden it outright since M2 for exactly this reason; every other pane simply obeyed,
/// so the app already overrode that preference in one place and honoured it in eight. The
/// inconsistency was the real defect, not the override.
///
/// The knob is a FIXED height rather than proportional to content. A proportional knob in a
/// tall file tree becomes a two-pixel speck that says nothing and cannot be aimed at; a fixed
/// one stays a legible marker of position. It gives up encoding how much content there is,
/// which the system scroller communicates poorly at these sizes anyway.
public struct TileScrollBar: View {
    /// How tall the knob is, whatever the content length.
    public static let knobHeight: CGFloat = 42
    /// Deliberately thinner than any system scroller: it floats over content, so it has to
    /// be findable without being furniture.
    public static let thickness: CGFloat = 4
    /// Inset from the pane's trailing edge and from its ends.
    public static let inset: CGFloat = 3

    /// 0...1 — how far down the content is.
    let progress: Double
    /// Whether the content is long enough to scroll at all.
    let isScrollable: Bool
    /// The height available to travel in.
    let trackHeight: CGFloat

    public init(progress: Double, isScrollable: Bool, trackHeight: CGFloat) {
        self.progress = progress
        self.isScrollable = isScrollable
        self.trackHeight = trackHeight
    }

    /// The travel available to the knob, never negative — a pane shorter than the knob has
    /// nowhere to move it, and a negative range would put the knob outside the pane.
    var travel: CGFloat {
        max(0, trackHeight - Self.knobHeight - 2 * Self.inset)
    }

    public var body: some View {
        if isScrollable, trackHeight > Self.knobHeight {
            Capsule(style: .continuous)
                .fill(Token.Colour.tertiaryLabel)
                .frame(width: Self.thickness,
                       height: min(Self.knobHeight, max(0, trackHeight - 2 * Self.inset)))
                .padding(.trailing, Self.inset)
                .offset(y: Self.inset + travel * clamped(progress))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                // No track behind it, and no hit testing: this REPORTS position, it is not a
                // control. A drag target here would compete with the content underneath for
                // a gesture the wheel and trackpad already handle.
                .allowsHitTesting(false)
        }
    }

    /// Rubber-band scrolling reports offsets past both ends, which would otherwise push the
    /// knob out of the pane at the moment the user is looking straight at it.
    private func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(1, max(0, value.isFinite ? value : 0)))
    }
}

public extension View {
    /// Replace a scroll view's system indicators with the pane's own.
    ///
    /// Applied to the ScrollView itself rather than a container: `onScrollGeometryChange`
    /// reads the nearest scroll view, and the overlay has to sit in its coordinate space to
    /// line up with the content it describes.
    func tileScrollBar() -> some View {
        modifier(TileScrollBarModifier())
    }
}

private struct TileScrollBarModifier: ViewModifier {
    @State private var progress: Double = 0
    @State private var isScrollable = false
    @State private var trackHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // `.never`, not `.hidden`. Hidden still lets macOS flash its own indicator
            // while scrolling, so the pane briefly wore two — a system scroller reserving
            // width beside our own capsule.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                let visible = geometry.containerSize.height
                let total = geometry.contentSize.height
                    + geometry.contentInsets.top + geometry.contentInsets.bottom
                let range = total - visible
                return ScrollSnapshot(
                    // The offset starts at minus the top inset, so it is measured from the
                    // top of the CONTENT rather than from zero. Without that, a scroll view
                    // with a content inset reports itself already scrolled at rest.
                    progress: range > 0
                        ? (geometry.contentOffset.y + geometry.contentInsets.top) / range
                        : 0,
                    isScrollable: range > 1,
                    trackHeight: visible)
            } action: { _, snapshot in
                progress = snapshot.progress
                isScrollable = snapshot.isScrollable
                trackHeight = snapshot.trackHeight
            }
            .overlay {
                // The track height is read from LAYOUT, not from the scroll geometry.
                // `onScrollGeometryChange` reports changes, and its first value is the
                // baseline rather than a change — so a pane that is never scrolled would
                // keep a track height of zero and draw nothing at all.
                GeometryReader { proxy in
                    TileScrollBar(progress: progress,
                                  isScrollable: isScrollable,
                                  trackHeight: proxy.size.height)
                }
            }
    }
}

/// One value, so the geometry callback fires on a single equatable change rather than three.
private struct ScrollSnapshot: Equatable {
    var progress: Double
    var isScrollable: Bool
    var trackHeight: CGFloat
}
