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
/// Sized to the TITLE band only. The icon on the left is the kind menu and the cluster on the
/// right is split and close; a drag starting on either of those is not a drag anyone meant,
/// so this sits between them and lets both keep their clicks.
@MainActor
final class PaneDragHandleView: NSView {
    private let paneID: PaneID
    /// A snapshot of the pane, so what you drag looks like what you are moving.
    private let snapshot: () -> NSImage?
    private var mouseDownAt: NSPoint?

    init(paneID: PaneID, snapshot: @escaping () -> NSImage?) {
        self.paneID = paneID
        self.snapshot = snapshot
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks pass through, drags do not.
    ///
    /// The header underneath still needs its taps — clicking the title focuses the pane, and
    /// swallowing that to enable a gesture nobody has started yet would break the common
    /// action to serve the rare one.
    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownAt = nil
        // Not a drag: hand the click on as a focus request.
        (superview as? PaneContainerView)?.focusFromHandle()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        // The system slop threshold. Below it this is a click that wobbled, and starting a
        // drag would make the header impossible to click precisely.
        guard (dx * dx + dy * dy).squareRoot() > 4 else { return }
        mouseDownAt = nil
        beginDrag(with: event)
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
