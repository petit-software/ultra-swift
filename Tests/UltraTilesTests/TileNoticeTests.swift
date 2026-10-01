import Testing
@testable import UltraTiles

/// The notices four tiles float over their content are one vocabulary: the same words for
/// the same event, and the same rule for which ones leave on their own.
@Suite("Tile notices")
struct TileNoticeTests {

    @Test("a reload is informational and leaves on its own")
    func reloadLeaves() {
        let notice = TileNotice.reloadedFromDisk
        #expect(notice.tone == .info)
        #expect(!notice.stays, "there is nothing to decide after a reload")
        #expect(notice.message.hasPrefix("Reloaded"))
    }

    @Test("a notice that needs a decision, or reports a failure, waits to be read")
    func decisionsStay() {
        for notice in [TileNotice.conflict,
                       .couldNotSave("permission denied"),
                       .failed("Could not open"),
                       .unreachable("Nothing is answering at localhost:5173")] {
            #expect(notice.stays, "\(notice.message) must not vanish before it is acted on")
            #expect(notice.tone != .info)
        }
    }

    @Test("a save that failed says so, with the system's reason")
    func couldNotSaveCarriesReason() {
        let notice = TileNotice.couldNotSave("permission denied")
        #expect(notice.message == "Could not save: permission denied")
        #expect(notice.tone == .failure)
    }

    @Test("a page or device that could not be reached is a warning, not a failure")
    func unreachableIsAWarning() {
        #expect(TileNotice.unreachable("x").tone == .warning)
        #expect(TileNotice.conflict.tone == .warning)
    }

    /// The glyph sits at 13pt beside a sentence; an outlined one at that size is a smudge.
    @Test("every notice wears a filled symbol")
    func symbolsAreFilled() {
        for notice in [TileNotice.reloadedFromDisk, .conflict, .couldNotSave("x"),
                       .failed("x"), .unreachable("x")] {
            #expect(notice.symbol.hasSuffix(".fill"), "\(notice.symbol)")
        }
    }
}
