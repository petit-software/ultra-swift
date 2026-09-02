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
///
/// It shows while the POINTER IS IN THE PANE and is otherwise invisible — see
/// `TileScrollBarModifier`. Position is worth reporting to someone who is reading the pane,
/// and a bar drawn down eight panes at once is eight vertical lines competing with the
/// content for the same edge.
public struct TileScrollBar: View {
    /// How tall the knob is, whatever the content length.
    public static let knobHeight: CGFloat = 42
    /// Deliberately thinner than any system scroller: it floats over content, so it has to
    /// be findable without being furniture.
    public static let thickness: CGFloat = 4
    /// Inset from the pane's trailing edge. Only from the SIDE — the track runs the full
    /// height of the scrollable area, so there is nothing to inset at the ends.
    public static let sideInset: CGFloat = 12
    /// The track behind the knob. Barely there on purpose: it says how far there is to go
    /// without becoming a second edge down the inside of the pane.
    public static let trackOpacity: Double = 0.08

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
        max(0, trackHeight - Self.knobHeight)
    }

    public var body: some View {
        if isScrollable, trackHeight > Self.knobHeight {
            ZStack(alignment: .top) {
                // The track runs the full height of the pane, so the knob's position reads
                // against the whole of what there is rather than against nothing.
                Capsule(style: .continuous)
                    .fill(Token.Colour.label.opacity(Self.trackOpacity))
                    .frame(width: Self.thickness, height: trackHeight)

                Capsule(style: .continuous)
                    .fill(Token.Colour.tertiaryLabel)
                    .frame(width: Self.thickness, height: Self.knobHeight)
                    .offset(y: travel * clamped(progress))
            }
            .frame(width: Self.thickness, height: trackHeight, alignment: .top)
            .padding(.trailing, Self.sideInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            // No hit testing: this REPORTS position, it is not a control. A drag target here
            // would compete with the content underneath for a gesture the wheel and trackpad
            // already handle.
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
    /// Whether the pointer is in this pane.
    ///
    /// Which is also, on this platform, whether the pane can be scrolled at all by wheel or
    /// trackpad: macOS scrolls what is under the pointer. So "on hover" is not a lesser
    /// version of "while scrolling" — it is the same moment, arriving slightly earlier.
    @State private var isHovering = false

    /// The scroll view's bottom content margin — the room the floating footer occupies.
    @State private var bottomInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // `.never`, not `.hidden`. Hidden still lets macOS flash its own indicator
            // while scrolling, so the pane briefly wore two — a system scroller reserving
            // width beside our own capsule.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                // `containerSize` is the VISIBLE area, with the content insets already taken
                // out of it. Adding those insets to the content as well counted the footer's
                // margin twice — once as extra range to travel and once as room already
                // removed — so the knob ran out of progress before the content ran out of
                // scroll and stopped short of the bottom. With a 36pt footer over a pane of
                // 500 showing 700 of content, that put its maximum at 200/236, which is the
                // three-quarters this presented as.
                let range = geometry.contentSize.height - geometry.containerSize.height
                return ScrollSnapshot(
                    // Measured from the top of the CONTENT rather than from zero: a scroll
                    // view with a top inset rests at minus that inset, and without the shift
                    // would report itself already scrolled before anyone touched it.
                    progress: range > 0
                        ? (geometry.contentOffset.y + geometry.contentInsets.top) / range
                        : 0,
                    isScrollable: range > 1,
                    trackHeight: geometry.containerSize.height,
                    bottomInset: geometry.contentInsets.bottom)
            } action: { _, snapshot in
                progress = snapshot.progress
                isScrollable = snapshot.isScrollable
                trackHeight = snapshot.trackHeight
                bottomInset = snapshot.bottomInset
            }
            // The whole scrollable area, so entering the pane is what shows the bar rather
            // than finding the four points of it. The bar itself takes no hits, so it cannot
            // shadow the content it sits over and end the hover it depends on.
            .onHover { isHovering = $0 }
            .overlay {
                // The track height is read from LAYOUT, not from the scroll geometry.
                // `onScrollGeometryChange` reports changes, and its first value is the
                // baseline rather than a change — so a pane that is never scrolled would
                // keep a track height of zero and draw nothing at all.
                GeometryReader { proxy in
                    // Shortened by the footer's own margin, so the track ends where the
                    // visible content does rather than running on underneath it — the last
                    // stretch of travel was hidden behind the footer.
                    TileScrollBar(progress: progress,
                                  isScrollable: isScrollable,
                                  trackHeight: max(0, proxy.size.height - bottomInset))
                        .opacity(isHovering ? 1 : 0)
                        .animation(Token.Motion.chromeFade, value: isHovering)
                }
            }
    }
}

/// One value, so the geometry callback fires on a single equatable change rather than three.
private struct ScrollSnapshot: Equatable {
    var progress: Double
    var isScrollable: Bool
    var trackHeight: CGFloat
    var bottomInset: CGFloat
}
