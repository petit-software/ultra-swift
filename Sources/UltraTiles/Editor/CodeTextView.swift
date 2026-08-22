import AppKit
import SwiftUI
import UltraDesign

/// A plain-text editing surface with line numbers.
///
/// `NSTextView` rather than SwiftUI's `TextEditor`, for two reasons that matter for code:
/// `TextEditor` cannot carry a line-number ruler, and it inherits the system's smart
/// substitutions — curly quotes and em dashes silently replacing what you typed, which is a
/// bug generator in a config file.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SaveAwareTextView()
        textView.onSave = onSave
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(Token.Colour.label)
        textView.insertionPointColor = NSColor(Token.Colour.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Every one of these turns a helpful prose feature into a code corrupter.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // Horizontal scrolling off: wrapping keeps long lines reachable in a narrow pane.
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SaveAwareTextView else { return }
        textView.onSave = onSave
        textView.isEditable = isEditable
        // Only when it genuinely differs: assigning the string resets the selection, so
        // doing it on every update would fight the cursor on every keystroke.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count),
                                              length: 0))
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: CodeTextView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
        }
    }
}

/// Takes ⌘S itself. The app's ⌘S saves the LAYOUT, and while you are typing in a file that
/// is not what the keystroke means.
final class SaveAwareTextView: NSTextView {
    var onSave: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Line numbers down the left edge.
///
/// Drawn per visible line rather than per line in the file: a 50,000-line file must cost the
/// same to scroll as a 50-line one.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(Token.Colour.tertiaryLabel),
        ]

        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                          actualGlyphRange: nil)
        let text = textView.string as NSString

        // The line number of the first visible line, counted once.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        text.enumerateSubstrings(in: characterRange,
                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let rect = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(forCharacterRange: range,
                                                        actualCharacterRange: nil),
                in: container)
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = rect.minY + textView.textContainerInset.height
                - textView.visibleRect.minY + (rect.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 6, y: y),
                       withAttributes: attributes)
            lineNumber += 1
        }
    }
}
