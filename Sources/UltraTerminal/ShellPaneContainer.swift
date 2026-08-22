import AppKit
import UltraDesign

/// Gives a terminal breathing room inside its pane.
///
/// SwiftTerm draws its grid flush to its own bounds and offers no content inset, so text
/// would otherwise sit hard against the pane's rounded edge. The container paints the
/// theme background across the full pane and insets the grid inside it, so the padding is
/// part of the terminal rather than a gap showing the pane behind.
@MainActor
public final class ShellPaneContainer: NSView {
    public let terminal: ShellTerminalView
    /// Horizontal padding is larger than vertical: a column of text wants room from the
    /// edge, a row does not need as much from the header.
    ///
    /// The top inset is deliberately SMALL, not the header's height. The header floats over
    /// the pane, and its progressive blur only exists if something passes underneath it — an
    /// inset that cleared the header would leave the ramp sitting on a flat background,
    /// which is the same as having no blur at all. Scrollback therefore rises under the
    /// title and dissolves into it, as it does in every other pane.
    public var contentInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

    public init(terminal: ShellTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(terminal)
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    /// The pane's glass is the background. This wrapper only ever adds padding.
    public func applyBackground() {
        layer?.backgroundColor = NSColor(terminal.spec.theme.background)
            .withAlphaComponent(terminal.spec.theme.backgroundOpacity).cgColor
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        terminal.frame = CGRect(
            x: contentInsets.left,
            y: contentInsets.top,
            width: max(0, bounds.width - contentInsets.left - contentInsets.right),
            height: max(0, bounds.height - contentInsets.top - contentInsets.bottom))
        CATransaction.commit()
    }

    /// The terminal takes the keyboard, not this wrapper. The canvas finds it by walking
    /// down to the first subview that accepts first-responder status.
    public override var acceptsFirstResponder: Bool { false }
}
