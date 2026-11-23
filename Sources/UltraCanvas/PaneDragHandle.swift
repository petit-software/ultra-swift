import AppKit
import UltraDesign
import UltraLayout

/// The band of a pane's header you can pick the pane up by.
///
/// AppKit, not SwiftUI. `.onDrag` on the header simply never fires: the header is an
/// `NSHostingView` floating over the pane's content, and this is the third control in that
/// view to render perfectly and do nothing — the kind menu and the focus tap were the other
/// two. Beginning the session ourselves removes the guesswork.
///
/// Sized to the EMPTY band only. Close, icon and name on the left are one control cluster and
/// the pair on the right is split; a drag starting on any of those is not a drag anyone
/// meant, so this sits between them and lets both ends keep their clicks.
@MainActor
final class PaneDragHandleView: NSView {
    private let paneID: PaneID
    /// What is carried under the pointer: a plain card of the pane's colour.
    private let snapshot: () -> NSImage?
    private var mouseDownAt: NSPoint?
    /// On a floating canvas: what moves it, by a translation from where the drag began
    /// and whether the drag has ended. Nil anywhere else, where the pane is picked up.
    var floatDrag: () -> ((CGSize, Bool) -> Void)? = { nil }
    /// A floating canvas on its way: where the button went down, and what moves it.
    private var moving: (start: NSPoint, move: (CGSize, Bool) -> Void)?

    init(paneID: PaneID, snapshot: @escaping () -> NSImage?) {
        self.paneID = paneID
        self.snapshot = snapshot
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks pass through, drags do not.
    ///
    /// The header underneath still needs its taps — clicking the empty band focuses the
    /// pane, and swallowing that to enable a gesture nobody has started yet would break the
    /// common action to serve the rare one.
    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownAt = nil
        if let moving {
            // The float is put down where the pointer left it.
            self.moving = nil
            moving.move(translation(to: event, from: moving.start), true)
            return
        }
        // Not a drag: hand the click on as a focus request.
        (superview as? PaneContainerView)?.focusFromHandle()
    }

    override func mouseDragged(with event: NSEvent) {
        if let moving {
            moving.move(translation(to: event, from: moving.start), false)
            return
        }
        guard let start = mouseDownAt else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        // The system slop threshold. Below it this is a click that wobbled, and starting a
        // drag would make the header impossible to click precisely.
        guard (dx * dx + dy * dy).squareRoot() > 4 else { return }
        mouseDownAt = nil
        if let move = floatDrag() {
            // A floating canvas goes with the pointer until the button comes up: the
            // view that took the press hears every move and the release, wherever the
            // canvas it rides has got to.
            moving = (start, move)
            move(translation(to: event, from: start), false)
        } else {
            beginDrag(with: event)
        }
    }

    /// How far the pointer is from where the button went down, in the canvas's terms.
    /// Measured in the WINDOW: this view rides the canvas it is moving, so a point in its
    /// own coordinates would chase itself. The window's y runs up, the canvas's down.
    private func translation(to event: NSEvent, from start: NSPoint) -> CGSize {
        CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y)
    }

    private func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(paneID.uuidString, forType: PaneDragType.pasteboard)
        let dragItem = NSDraggingItem(pasteboardWriter: item)

        let image = snapshot()
        let size = image?.size ?? CGSize(width: 220, height: 140)
        let origin = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(CGRect(x: origin.x - size.width / 2,
                                         y: origin.y - size.height / 2,
                                         width: size.width, height: size.height),
                                  contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
}

extension PaneDragHandleView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Within the app only: a pane has no meaning anywhere else, and offering it to other
        // applications would advertise a drop that cannot work.
        context == .withinApplication ? .move : []
    }
}
