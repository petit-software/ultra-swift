import AppKit
import SwiftUI
import UltraDesign
import UltraLayout

/// The panes floating over a session's canvas: each a canvas of its own, at the place it
/// was put. See `LayoutStore.floatPane`.
///
/// Laid over the tiling in the canvas's own coordinates, so a float's frame means the
/// same thing to the store, to this view and to the pane under it. Empty where no pane
/// floats, and what is empty takes no click: the tiling underneath keeps every one of its
/// own.
///
/// Moved by the frame round it — a band of glass on every side, there to be taken hold
/// of — and by its header's band, like a window by its title bar (`PaneDragHandleView`);
/// resized from its four corners. From the keys: Pane ▸ Float Pane and Pane ▸ Dock Pane.
struct FloatingPanes: View {
    let store: LayoutStore

    var body: some View {
        // Registers the dependency: a pane floating or docking, and their order.
        let _ = store.floatRevision
        ZStack(alignment: .topLeading) {
            ForEach(store.floats, id: \.floatIdentity) { float in
                FloatingPane(float: float, canvas: store.canvasBounds)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension LayoutStore {
    /// A floating canvas's identity in a list of them: the store itself.
    fileprivate var floatIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}

/// One floating canvas, where it is, in the frame it is moved by.
private struct FloatingPane: View {
    let float: LayoutStore
    /// The canvas it floats over, which it is kept on: a window made smaller brings a
    /// pane left beyond its new edge back within reach.
    let canvas: CGRect
    /// Whether the pointer is over it, frame included: when the frame shows.
    @State private var isHovering = false

    var body: some View {
        // Held, it is wherever the drag has it — past an edge, a little. Otherwise where
        // the canvas keeps it.
        let frame = float.isFloatHeld ? float.floatFrame
                                      : LayoutStore.floatFrame(float.floatFrame, fitting: canvas)
        // The pane's corners, and the frame's width round them.
        let radius = Token.Space.paneRadius + LayoutStore.floatFrameWidth
        SplitCanvas(store: float)
            .frame(width: frame.width, height: frame.height)
            // The frame: a plate of glass the pane is set into, showing as a band round
            // it. Under the canvas, which lays its pane out inside by the band's width.
            .background {
                ZStack {
                    // Lifted: what says this pane is over the others, not among them.
                    // Cast by a shape of its own under the pane, since glass casts none
                    // and the band is not always there.
                    RoundedRectangle(cornerRadius: Token.Space.paneRadius, style: .continuous)
                        .fill(.black.opacity(0.2))
                        .padding(LayoutStore.floatFrameWidth)
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    // The band, under the pointer only — and while it is held, which a
                    // fast drag can outrun. At rest the pane is just a pane, floating.
                    ZStack {
                        if Token.Environment_.reduceTransparency {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Token.Colour.tileBackground)
                        } else {
                            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: radius))
                        }
                        // A wash and a hairline, so the band reads as a thing to take
                        // hold of over whatever is under it.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Token.Colour.label.opacity(0.08))
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Token.Colour.label.opacity(0.18), lineWidth: 1)
                    }
                    .opacity(isHovering || float.isFloatHeld ? 1 : 0)
                    .animation(Token.Environment_.reduceMotion ? nil : .easeOut(duration: 0.15),
                               value: isHovering || float.isFloatHeld)
                }
            }
            .onHover { isHovering = $0 }
            .overlay { FloatFrameGrips(float: float) }
            .offset(x: frame.minX, y: frame.minY)
            // Let go past an edge, it springs back to where the canvas keeps it. Not
            // while held: a pane that lagged the pointer would feel like dragging it
            // through something.
            .animation(float.isFloatHeld || Token.Environment_.reduceMotion ? nil
                           : .spring(response: 0.38, dampingFraction: 0.62),
                       value: frame.origin)
            .accessibilityLabel("Floating pane")
    }
}

/// The frame of a floating canvas as something to take hold of: its four sides move it,
/// its four corners resize it.
private struct FloatFrameGrips: View {
    let float: LayoutStore
    /// The frame when a drag began.
    @State private var origin: CGRect?

    private enum Grip { case move, topLeft, topRight, bottomLeft, bottomRight }

    private let width = LayoutStore.floatFrameWidth
    /// A corner's reach along each side: the frame's width and the pane's corner.
    private var corner: CGFloat { width + Token.Space.paneRadius }

    var body: some View {
        ZStack {
            grip(.move, cursor: .openHand)
                .frame(height: width).frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, corner)
            grip(.move, cursor: .openHand)
                .frame(height: width).frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, corner)
            grip(.move, cursor: .openHand)
                .frame(width: width).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, corner)
            grip(.move, cursor: .openHand)
                .frame(width: width).frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, corner)
            cornerGrip(.topLeft, .topLeading, .frameResize(position: .topLeft, directions: .all))
            cornerGrip(.topRight, .topTrailing, .frameResize(position: .topRight, directions: .all))
            cornerGrip(.bottomLeft, .bottomLeading, .frameResize(position: .bottomLeft, directions: .all))
            cornerGrip(.bottomRight, .bottomTrailing, .frameResize(position: .bottomRight, directions: .all))
        }
    }

    /// A corner: the two arms of the frame that meet there, not the square between them —
    /// that square's inside is the pane's own corner, which keeps its clicks.
    private func cornerGrip(_ which: Grip, _ alignment: Alignment, _ cursor: NSCursor) -> some View {
        let isTop = which == .topLeft || which == .topRight
        let isLeft = which == .topLeft || which == .bottomLeft
        return ZStack {
            grip(which, cursor: cursor)
                .frame(width: corner, height: width)
                .frame(maxHeight: .infinity, alignment: isTop ? .top : .bottom)
            grip(which, cursor: cursor)
                .frame(width: width, height: corner)
                .frame(maxWidth: .infinity, alignment: isLeft ? .leading : .trailing)
        }
        .frame(width: corner, height: corner)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func grip(_ which: Grip, cursor: NSCursor) -> some View {
        Color.clear
            .contentShape(.rect)
            .onHover { inside in
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            // In the window's space: the grip moves as the frame does, and a translation
            // measured in its own would chase itself.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = origin ?? float.floatFrame
                    if origin == nil {
                        origin = start
                        // Taking hold of it is taking the keyboard to it, as a click on
                        // a window's edge brings the window forward.
                        float.activateCanvas()
                    }
                    float.setFloatFrame(Self.frame(start, dragging: which, by: value.translation),
                                        settled: false)
                }
                .onEnded { value in
                    let start = origin ?? float.floatFrame
                    origin = nil
                    float.setFloatFrame(Self.frame(start, dragging: which, by: value.translation))
                })
            .accessibilityHidden(true)
    }

    /// The frame moved, or with one corner dragged — never narrower or shorter than the
    /// least a float can be: the corner stops there rather than pushing the far side along.
    private static func frame(_ start: CGRect, dragging grip: Grip, by translation: CGSize) -> CGRect {
        if grip == .move { return start.offsetBy(dx: translation.width, dy: translation.height) }
        let least = LayoutStore.minFloatSize
        var frame = start
        if grip == .topLeft || grip == .bottomLeft {
            let dx = min(translation.width, start.width - least.width)
            frame.origin.x += dx
            frame.size.width -= dx
        } else {
            frame.size.width = max(least.width, start.width + translation.width)
        }
        if grip == .topLeft || grip == .topRight {
            let dy = min(translation.height, start.height - least.height)
            frame.origin.y += dy
            frame.size.height -= dy
        } else {
            frame.size.height = max(least.height, start.height + translation.height)
        }
        return frame
    }
}

#Preview("Floating pane", traits: .fixedLayout(width: 900, height: 600)) {
    let store = LayoutStore.placeholders(.threeAcross)
    store.assumeCanvasBounds(CGRect(x: 0, y: 0, width: 900, height: 600))
    store.floatPane()
    return CanvasSurface(store: store)
}
