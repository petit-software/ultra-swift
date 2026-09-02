import AppKit
import Testing
@testable import UltraDesign

/// At 15pt an outline glyph reads as a lighter control than the filled one beside it, so
/// chrome resolves every icon to its fill — where the system has one.
@MainActor
@Suite("Chrome icons are filled")
struct ChromeSymbolTests {

    @Test("a symbol with a fill variant is drawn filled")
    func fillVariantIsPreferred() {
        #expect(ChromeSymbol.filled("folder") == "folder.fill")
        #expect(ChromeSymbol.filled("square.split.2x1") == "square.split.2x1.fill")
        #expect(ChromeSymbol.filled("apple.terminal") == "apple.terminal.fill")
        #expect(ChromeSymbol.filled("minus.circle") == "minus.circle.fill")
    }

    @Test("an already-filled symbol is left alone")
    func fillIsNotDoubled() {
        #expect(ChromeSymbol.filled("folder.fill") == "folder.fill")
    }

    /// The failure this guards is a blank control: `Image(systemName:)` draws NOTHING for a
    /// name the system does not have, with no error anywhere.
    @Test("a symbol with no fill keeps its own name")
    func missingFillFallsBack() {
        for symbol in ["xmark", "command", "arrow.right.to.line", "plus"] {
            let drawn = ChromeSymbol.filled(symbol)
            #expect(NSImage(systemSymbolName: drawn, accessibilityDescription: nil) != nil,
                    "\(symbol) resolved to \(drawn), which does not draw")
        }
    }
}
