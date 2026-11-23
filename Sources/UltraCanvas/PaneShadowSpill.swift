import AppKit
import SwiftUI
import UltraDesign

/// The part of the panes' shadows that falls outside the canvas, drawn where it falls.
///
/// Nothing clips the canvas: a pane's shadow runs past the canvas's edge as far as it
/// reaches. But the sidebar is a column of its own, laid OVER the detail column's edge,
/// and it carries its own copy of the window's surface (`SessionSidebar.body`) — a
/// material that shows the desktop behind the window, and so nothing of what is under it
/// in the window. The panes beside the sidebar stand on the column's edge, and their
/// shadows stopped there, on a straight line down the window.
///
/// The surface cannot go under the panes, so the shadow goes over the surface: this view
/// is laid in the sidebar, between its surface and its list, and draws each pane's
/// shadow again — the same path, radius, offset and strength, read off the pane — at the
/// pane's place in the window. It is clipped to the sidebar, so only what falls here is
/// drawn here, and the two halves meet on the column's edge.
public struct PaneShadowSpill: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView { PaneShadowSpillView() }
    public func updateNSView(_ nsView: NSView, context: Context) { nsView.needsLayout = true }

    /// Posted by a canvas and by its panes when a shadow has moved or changed.
    static let changed = Notification.Name("ultra.paneShadowSpill.changed")
}

private final class PaneShadowSpillView: NSView {
    private var shadows: [CALayer] = []
    private var observers = ObserverBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: PaneShadowSpill.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// As the panes are, so a shadow's offset means the same thing here as there.
    override var isFlipped: Bool { true }

    /// Nothing here is clickable: it is a shadow.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        var panes: [PaneContainerView] = []
        if let content = window?.contentView { Self.collect(from: content, into: &panes) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var used = 0
        for pane in panes {
            guard let source = pane.layer, source.shadowOpacity > 0,
                  let path = source.shadowPath else { continue }
            let frame = convert(pane.bounds, from: pane)
            // As far as a shadow shows: its blur, and how far it is set off.
            let reach = source.shadowRadius * 2
                + max(abs(source.shadowOffset.width), abs(source.shadowOffset.height))
            guard frame.insetBy(dx: -reach, dy: -reach).intersects(bounds) else { continue }
            if used == shadows.count {
                let shadow = CALayer()
                layer.addSublayer(shadow)
                shadows.append(shadow)
            }
            let shadow = shadows[used]
            used += 1
            shadow.isHidden = false
            shadow.frame = frame
            shadow.shadowPath = path
            shadow.shadowColor = source.shadowColor
            shadow.shadowOffset = source.shadowOffset
            shadow.shadowRadius = source.shadowRadius
            shadow.shadowOpacity = source.shadowOpacity
        }
        for shadow in shadows[used...] { shadow.isHidden = true }
        CATransaction.commit()
    }

    /// Every pane of every canvas tiled in the window. Not a floating pane's: its shadow
    /// is its frame's, and it is over the canvas, not beside the sidebar.
    private static func collect(from view: NSView, into panes: inout [PaneContainerView]) {
        if view.isHidden { return }
        if let canvas = view as? SplitCanvasView, canvas.store.isFloating { return }
        if let pane = view as? PaneContainerView {
            panes.append(pane)
            return
        }
        for subview in view.subviews { collect(from: subview, into: &panes) }
    }
}
