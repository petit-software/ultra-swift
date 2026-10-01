import AppKit
import SwiftUI
import UltraDesign

/// A text editing surface with line numbers and, for a file in a language it knows, the
/// generic colouring of `CodeHighlighter`.
///
/// `NSTextView` rather than SwiftUI's `TextEditor`, for two reasons that matter for code:
/// `TextEditor` cannot carry a line-number ruler, and it inherits the system's smart
/// substitutions — curly quotes and em dashes silently replacing what you typed, which is a
/// bug generator in a config file.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// What the text is written in, or nil for plain text. See `CodeLanguage.detect`.
    var language: CodeLanguage? = nil
    /// Asked once, as the view is made: whether it should take the keyboard when it lands
    /// in a window. A question rather than a flag so the answer can be "yes, this once" —
    /// see `EditorDocument.claimInitialFocus`.
    var claimsFocus: () -> Bool = { false }
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Pinned, for the same reason `ShellTerminalView` pins it: with "Show scroll bars:
        // Always" — which is what a user gets the moment a mouse is attached — macOS makes
        // every scroller `.legacy`, and a legacy scroller RESERVES width instead of floating
        // over the content. That is a permanent grey gutter down a pane that is already as
        // narrow as the user made it, and `autohidesScrollers` does not prevent it.
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SaveAwareTextView()
        textView.onSave = onSave
        textView.focusesOnAppear = claimsFocus()
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
        // Colouring is applied to the storage as it changes, not to the string as it is
        // set: the text view's own edits — typing, paste, undo — never come through
        // `updateNSView`, and they have to be coloured too.
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.language = language

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
            // The text was replaced from OUTSIDE — another file in this pane, or a reload
            // from disk — and none of that went through the undo manager. Entries still on
            // the stack belong to text that is no longer there; applying one would splice
            // old characters into the new file at ranges that mean nothing now.
            context.coordinator.undoManager.removeAllActions()
            textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count),
                                              length: 0))
            context.coordinator.ruler?.needsDisplay = true
        }
        // A new file that has just been saved as `notes.py` turns from plain text into
        // Python without its view being remade.
        if context.coordinator.language != language {
            context.coordinator.language = language
            if let storage = textView.textStorage { context.coordinator.highlight(storage) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        private let parent: CodeTextView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        var language: CodeLanguage?
        /// This view's own history. Without one, a text view registers into the WINDOW's
        /// undo manager, which every text field in every tile shares — so ⌘Z in a file
        /// could take back a rename typed into the todo list an hour ago. `UndoRouting`
        /// hands ⌘Z to whatever manager the focused text view reports, and this is it.
        let undoManager = UndoManager()

        init(_ parent: CodeTextView) { self.parent = parent }

        nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
            MainActor.assumeIsolated { undoManager }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
        }

        /// Characters changed — by a keystroke, a paste, an undo or a reload — so the
        /// colours are stale. Attribute-only edits are ignored, because this method makes
        /// them and would otherwise be answering itself.
        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), language != nil else { return }
            highlight(storage)
        }

        /// Colour the whole text. Whole rather than the edited paragraph, because a block
        /// comment or a multi-line string opened three screens up changes what the line
        /// under the caret means, and finding where to restart from costs as much as the
        /// scan. The scan is one linear pass over code units, which is fast enough for
        /// any file a person edits by hand; past a megabyte it is left plain.
        func highlight(_ storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            guard full.length > 0 else { return }
            // The face is reset along with the colour: a Markdown heading is bold, and
            // the bold must not outlive the `#` that made it.
            storage.addAttributes([.foregroundColor: NSColor(Token.Colour.label), .font: Self.baseFont],
                                  range: full)
            guard let language, full.length <= 1_000_000 else { return }
            for token in CodeHighlighter.tokens(in: storage.string, language: language) {
                storage.addAttribute(.foregroundColor, value: Self.colour(for: token.kind),
                                     range: token.range)
                if let font = Self.font(for: token.kind) {
                    storage.addAttribute(.font, value: font, range: token.range)
                }
            }
        }

        static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        /// System colours, every one dynamic, so the same file reads in light and dark
        /// appearance and under Increase Contrast without a palette of our own to keep.
        static func colour(for kind: CodeTokenKind) -> NSColor {
            switch kind {
            case .keyword: .systemPurple
            case .string: .systemRed
            case .comment: .secondaryLabelColor
            case .number: .systemBlue
            case .type: .systemTeal
            case .attribute: .systemOrange
            // Markdown. Headings take the keyword colour — they are the file's shape — and
            // links the number's; emphasis is carried by the face alone, below.
            case .heading: .systemPurple
            case .strong, .emphasis: NSColor(Token.Colour.label)
            case .code: .systemTeal
            case .link: .systemBlue
            case .marker: .systemOrange
            }
        }

        /// The face a kind is set in, where the colour is not the whole of it: bold for a
        /// heading and for `**strong**`, italic for `*emphasis*`. Still monospaced — the
        /// editor is one column of code and prose in it is prose in a code font — and
        /// still 12pt, so a heading does not change the height of its line and the ruler's
        /// numbers stay beside the lines they count.
        static func font(for kind: CodeTokenKind) -> NSFont? {
            switch kind {
            case .heading, .strong:
                return .monospacedSystemFont(ofSize: 12, weight: .bold)
            case .emphasis:
                let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
                return NSFont(descriptor: descriptor, size: 12) ?? baseFont
            default:
                return nil
            }
        }
    }
}

/// Takes ⌘S itself. The app's ⌘S saves the LAYOUT, and while you are typing in a file that
/// is not what the keystroke means.
final class SaveAwareTextView: NSTextView {
    var onSave: () -> Void = {}
    var focusesOnAppear = false

    /// A turn later, because the view is put in the window in the middle of a layout pass,
    /// and the canvas settles its own focus in the same pass — asking now would be asking
    /// first and being overruled.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnAppear, window != nil else { return }
        focusesOnAppear = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

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
        // Since macOS 14 a view's drawing is NOT clipped to its bounds, and `NSRulerView`
        // paints its background and its edge line across the whole rect it is asked to
        // draw — so the ruler's column ran on through the tab strip above it and the
        // footer below, as a line through chrome that is not the editor's. The frame was
        // right all along; only the paint overflowed.
        clipsToBounds = true
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
