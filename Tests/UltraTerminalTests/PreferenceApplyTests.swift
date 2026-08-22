import Testing
import AppKit
import Foundation
@testable import UltraTerminal
@testable import UltraDesign
@testable import UltraLayout

/// A preference that changes a number but not the running terminal is worse than no
/// preference. These cover the reach: settings → live shell.
@Suite("Preferences reach live shells", .serialized)
@MainActor
struct PreferenceApplyTests {

    private func factoryWithOneShell() -> (ShellPaneFactory, PaneID) {
        let factory = ShellPaneFactory(theme: Preferences.resolvedTheme(),
                                       defaultDirectory: NSTemporaryDirectory())
        let paneID = PaneID()
        _ = factory.makeContent(for: paneID)
        return (factory, paneID)
    }

    @Test("a new shell is built at the configured font size")
    func newShellUsesTheSetting() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = Preferences.store
        Preferences.store = suite
        defer { Preferences.store = previous; suite.removePersistentDomain(forName: name) }
        Preferences.terminalFontSize = 19

        let (factory, paneID) = factoryWithOneShell()
        #expect(factory.shells[paneID]?.font.pointSize == 19)
        factory.release(paneID)
    }

    @Test("changing the size reaches a shell that already exists")
    func applyFontReachesLiveShell() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = Preferences.store
        Preferences.store = suite
        defer { Preferences.store = previous; suite.removePersistentDomain(forName: name) }
        let (factory, paneID) = factoryWithOneShell()
        let original = try! #require(factory.shells[paneID]?.font.pointSize)

        Preferences.terminalFontSize = 24
        factory.applyFont()

        #expect(factory.shells[paneID]?.font.pointSize == 24)
        #expect(original != 24, "the test needs the size to actually change")
        factory.release(paneID)
    }

    @Test("the theme reaches a live shell, opacity and all")
    func applyThemeReachesLiveShell() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = Preferences.store
        Preferences.store = suite
        defer { Preferences.store = previous; suite.removePersistentDomain(forName: name) }
        let (factory, paneID) = factoryWithOneShell()

        Preferences.terminalBackgroundOpacity = 0.75
        Preferences.themeMode = .light
        factory.apply(theme: Preferences.resolvedTheme())

        let shell = try! #require(factory.shells[paneID])
        #expect(!shell.spec.theme.isDark)
        #expect(abs(shell.spec.theme.backgroundOpacity - 0.75) < 0.0001)
        // SwiftTerm carries the opacity in the background colour's alpha.
        #expect(abs(shell.nativeBackgroundColor.alphaComponent - 0.75) < 0.01)
        factory.release(paneID)
    }

    @Test("a zero-opacity theme leaves the terminal painting no background at all")
    func zeroOpacityIsFullyTransparent() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = Preferences.store
        Preferences.store = suite
        defer { Preferences.store = previous; suite.removePersistentDomain(forName: name) }
        let (factory, paneID) = factoryWithOneShell()
        factory.apply(theme: Preferences.resolvedTheme())

        let shell = try! #require(factory.shells[paneID])
        #expect(shell.nativeBackgroundColor.alphaComponent < 0.01,
                "at 0 the pane's glass IS the shell's surface")
        factory.release(paneID)
    }

    @Test("applying the same font twice does not churn every shell")
    func applyFontIsIdempotent() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = Preferences.store
        Preferences.store = suite
        defer { Preferences.store = previous; suite.removePersistentDomain(forName: name) }
        let (factory, paneID) = factoryWithOneShell()
        Preferences.terminalFontSize = 15
        factory.applyFont()
        let font = try! #require(factory.shells[paneID]?.font)
        factory.applyFont()
        // Same object identity matters: a font reassignment re-measures the grid and
        // triggers an authoritative PTY resize, which a no-op must not do.
        #expect(factory.shells[paneID]?.font === font)
        factory.release(paneID)
    }
}
