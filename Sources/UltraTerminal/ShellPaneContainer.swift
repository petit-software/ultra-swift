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
    /// The top inset clears the pane header, which floats over the content.
    ///
    /// A terminal grid draws its first row at the top and grows DOWNWARD, so a grid that
    /// extends under the header puts the prompt beneath the title on a fresh shell — the
    /// one line you always need to see. That is the opposite of a list, which fills from the
    /// top and is only ever interesting once it is long enough to scroll.
    ///
    /// The header's blur is not lost by this: `backgroundOpacity` is 0 by default, so this
    /// container is transparent and the pane's own glass is what shows through the header
    /// band. The ramp still has a real surface to work on — just not the shell's text.
    public var contentInsets = NSEdgeInsets(top: Token.Space.tileHeaderHeight + 4,
                                            left: 10, bottom: 6, right: 10)

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
