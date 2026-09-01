import Testing
@testable import UltraDesign

/// The palette and the symbol catalogue are both written to disk by name, so both have to
/// survive a name that is no longer in them.
@Suite("Session icon palette")
struct SessionTintTests {

    @Test("every stored tint name round trips")
    func rawValuesRoundTrip() {
        for tint in SessionTint.allCases {
            #expect(SessionTint(storedValue: tint.rawValue) == tint)
        }
    }

    /// A palette that drops a colour in a later version must not leave a row with no colour.
    @Test("an unknown tint falls back to the accent")
    func unknownTintFallsBack() {
        #expect(SessionTint(storedValue: "chartreuse") == .accent)
        #expect(SessionTint(storedValue: "") == .accent)
    }

    @Test("every tint has a name for VoiceOver")
    func everyTintIsNamed() {
        for tint in SessionTint.allCases {
            #expect(!tint.title.isEmpty)
        }
    }

    /// The one that actually catches a typo. An SF Symbol name that does not resolve draws
    /// NOTHING — a blank row, with no error anywhere to explain it.
    @Test("every offered symbol exists on this system")
    func everySymbolResolves() {
        for symbol in SessionSymbols.all {
            #expect(SessionSymbols.exists(symbol), "missing SF Symbol: \(symbol)")
        }
    }

    @Test("an unknown symbol falls back to one that draws")
    func unknownSymbolFallsBack() {
        #expect(SessionSymbols.resolved("not.a.symbol.at.all") == SessionSymbols.fallback)
        #expect(SessionSymbols.resolved("flame.fill") == "flame.fill")
    }

    /// A REAL symbol that is not in the catalogue — the shape an icon chosen by an older
    /// build has. Drawing it would put one outline glyph in a sidebar of filled ones.
    @Test("a real symbol outside the catalogue still falls back")
    func offCatalogueFallsBack() {
        #expect(SessionSymbols.exists("flame"))
        #expect(SessionSymbols.resolved("flame") == SessionSymbols.fallback)
    }

    /// At 15pt an outline symbol is a few hairlines of colour and reads as a smudge next to
    /// a filled one. The grid has to be one weight, so every entry is a `.fill`.
    @Test("every offered symbol is a fill variant")
    func everySymbolIsFilled() {
        for symbol in SessionSymbols.all {
            #expect(symbol.hasSuffix(".fill"), "not a fill variant: \(symbol)")
        }
    }

    @Test("the fallback is itself in the catalogue")
    func fallbackIsOffered() {
        #expect(SessionSymbols.all.contains(SessionSymbols.fallback))
    }

    /// The grid is laid out row-wise, and the list is written in themed rows. A count that
    /// is not a whole number of rows leaves the last theme ragged under a tidy grid — and,
    /// more usefully, catches a symbol appended to the end instead of into its group.
    @Test("the catalogue is a whole number of grid rows")
    func wholeRows() {
        #expect(SessionSymbols.all.count % SessionSymbols.columns == 0,
                "\(SessionSymbols.all.count) symbols does not fill rows of \(SessionSymbols.columns)")
    }

    /// Nothing may LEAVE the catalogue: `resolved` sends an off-catalogue name back to the
    /// default, so dropping a symbol silently resets every session that had chosen it.
    @Test("the symbols earlier builds offered are all still offered")
    func nothingIsEverRemoved() {
        let shipped = ["square.split.2x1.fill", "folder.fill", "apple.terminal.fill",
                       "curlybraces.square.fill", "hammer.fill", "wrench.and.screwdriver.fill",
                       "gearshape.fill", "cpu.fill", "cube.fill", "shippingbox.fill",
                       "externaldrive.fill", "cloud.fill", "globe.americas.fill", "lock.fill",
                       "bolt.fill", "flame.fill", "leaf.fill", "flask.fill", "paintbrush.fill",
                       "book.fill", "doc.text.fill", "star.fill", "heart.fill", "bookmark.fill"]
        for symbol in shipped {
            #expect(SessionSymbols.all.contains(symbol),
                    "\(symbol) was offered by an earlier build; removing it resets whoever chose it")
        }
    }

    @Test("the catalogue has no duplicates")
    func noDuplicates() {
        #expect(Set(SessionSymbols.all).count == SessionSymbols.all.count)
    }
}
