import Testing
@testable import UltraCore
@testable import UltraDesign

/// `UltraCore` sits below `UltraDesign` and cannot see the symbol catalogue, so the default
/// icon is spelled in both — once as `SessionAppearance.defaultSymbol` and once as
/// `SessionSymbols.fallback`. Only a test that imports both can hold them together, and this
/// is the lowest module that does.
///
/// Drift is quiet rather than loud: a mismatch leaves `resolved` throwing every uncustomised
/// row's symbol away and substituting a different one, which looks like a preference that
/// will not stick.
@Suite("The default session icon is one value")
struct SessionIconDefaultTests {

    @Test("both modules spell the default the same way")
    func defaultsAgree() {
        #expect(SessionAppearance.defaultSymbol == SessionSymbols.fallback)
    }

    @Test("the default icon survives a round trip through the catalogue")
    func defaultResolvesToItself() {
        #expect(SessionSymbols.resolved(SessionAppearance.default.symbol)
                == SessionAppearance.defaultSymbol)
    }

    /// The other half of the same pairing: `SessionAppearance.defaultTint` names a colour
    /// the palette actually has, or every uncustomised row silently becomes the accent by
    /// way of the unknown-value fallback rather than by choice.
    @Test("the default tint is a real palette entry")
    func defaultTintExists() {
        #expect(SessionTint(rawValue: SessionAppearance.defaultTint) != nil)
    }
}
