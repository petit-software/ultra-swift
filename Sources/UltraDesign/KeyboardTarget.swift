import AppKit

/// A pane's content that knows better than the view tree which of its views should take the
/// keyboard when the pane is focused.
///
/// The canvas otherwise picks the FIRST view that accepts first responder, depth first. That
/// is right for a shell (its terminal) and an editor (its text), and wrong for a browser
/// pane, whose address field comes before its page: focusing the pane with ⌘1 put the caret
/// in the address rather than on the page you were reading.
///
/// Here rather than in `UltraCanvas` because the tiles cannot import the canvas — they sit
/// beside it, not above it — and this is the lowest module both already see.
@MainActor
public protocol KeyboardTargetProviding: AnyObject {
    /// The view to focus, or nil to fall back to the canvas's own choice.
    var preferredKeyboardTarget: NSView? { get }
}
