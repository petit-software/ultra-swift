import AppKit
import SwiftUI
import UltraDesign

/// A one-line text field that does not move when it is clicked.
///
/// SwiftUI's `.plain` `TextField` is an `NSTextField` underneath, and on macOS the two halves
/// of that control disagree by a point about where a line of text sits: the cell draws the
/// placeholder one way, and the field editor that replaces it on focus draws it another.
/// Measured offscreen at 15pt: the glyphs rise two pixels the instant the field is clicked,
/// and drop back when it is left. A `Text` beside it does not move, so the composer's own
/// placeholder was the one thing in the pane that flinched at the pointer.
///
/// The same `NSTextField`, configured directly, does not do this — bezel off, background off,
/// focus ring off, single-line mode on — so this is that, with the three things a SwiftUI
/// caller needs from it: the text, whether it has focus, and Return.
struct SingleLineField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Token.Type_.tileSubtitleFont
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Focus follows the binding in both directions. Deferred, because this runs inside
        // a SwiftUI update and moving the first responder synchronously here re-enters it.
        let editing = field.currentEditor() != nil
        if isFocused, !editing {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        } else if !isFocused, editing {
            DispatchQueue.main.async { field.window?.makeFirstResponder(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SingleLineField
        init(parent: SingleLineField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
