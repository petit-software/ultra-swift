import AppKit

/// Which undo manager ⌘Z drives.
///
/// The layout has an undo stack of its own (`LayoutStore.undoManager`), and Edit ▸ Undo used
/// to be wired straight to it. The main menu sees a key equivalent before the responder
/// chain does, so that item won ⌘Z from every text view in the window — and the most recent
/// layout change under a freshly opened editor is the split that opened it. ⌘Z in the editor
/// closed the editor.
///
/// AppKit's own `undo:` cannot be leaned on instead: the window handles it, and for a plain
/// view as first responder it consults the WINDOW's undo manager rather than walking the
/// responder chain, so a canvas that offered the layout's manager through `undoManager`
/// would never be asked while a terminal had the keyboard. (Verified, not assumed.) The
/// routing therefore stays in the app's menu item and is decided here, at the moment the
/// key is pressed, from what has the keyboard.
///
/// The rule is the one every Mac app follows without stating it: when text is being edited,
/// ⌘Z is the text's. Everything else is the layout's.
@MainActor
public enum UndoRouting {

    /// The manager to undo or redo with, or nil when the keyboard is in a text view that
    /// keeps no history — in which case the answer is a beep, never the layout's stack. A
    /// user typing in a field must not have the pane pulled out from under them because the
    /// field happened to have nothing to take back.
    public static func manager(for store: LayoutStore?,
                               firstResponder: NSResponder?) -> UndoManager? {
        // `NSText` rather than `NSTextView`: the field editor behind every `NSTextField`
        // and SwiftUI `TextField` is one too, and a todo being renamed is text being edited.
        if let text = firstResponder as? NSText {
            guard let manager = text.undoManager, manager !== store?.undoManager else {
                return nil
            }
            return manager
        }
        return store?.undoManager
    }

    /// The manager for the key window right now.
    public static func current(for store: LayoutStore?) -> UndoManager? {
        manager(for: store, firstResponder: NSApp.keyWindow?.firstResponder)
    }
}
