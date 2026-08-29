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

    @Test("the catalogue has no duplicates")
    func noDuplicates() {
        #expect(Set(SessionSymbols.all).count == SessionSymbols.all.count)
    }
}
