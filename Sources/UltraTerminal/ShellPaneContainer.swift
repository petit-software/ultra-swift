import AppKit
import UltraDesign

/// Gives a terminal breathing room inside its pane.
///
/// SwiftTerm draws its grid flush to its own bounds and offers no content inset, so text
/// would otherwise sit hard against the pane's rounded edge. This wrapper adds that inset
/// and NOTHING else — it deliberately paints no background.
///
/// It used to paint the theme background across the full pane, while SwiftTerm painted the
/// same translucent colour again across the grid inside it. Two fills over one another are
/// not the fill the user asked for: at 50% the padding read 50% and the text read 75%, so
/// every terminal wore a visible frame of its own background. The pane's surface
/// (`PaneContainerView.theme`) is now the only thing that paints it, once, for every kind
/// of pane alike.
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
    /// The header's blur is not lost by this: this container paints nothing, so what shows
    /// through the header band is the pane's own surface. The ramp still has a real surface
    /// to work on — just not the shell's text.
    public var contentInsets = NSEdgeInsets(top: Token.Space.tileHeaderHeight + 4,
                                            left: 10, bottom: 6, right: 10)

    public init(terminal: ShellTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

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
