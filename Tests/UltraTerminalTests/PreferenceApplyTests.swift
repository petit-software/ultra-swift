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
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            Preferences.terminalFontSize = 19

            let (factory, paneID) = factoryWithOneShell()
            #expect(factory.shells[paneID]?.font.pointSize == 19)
            factory.release(paneID)
        }
    }

    @Test("changing the size reaches a shell that already exists")
    func applyFontReachesLiveShell() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            let (factory, paneID) = factoryWithOneShell()
            let original = try! #require(factory.shells[paneID]?.font.pointSize)

            Preferences.terminalFontSize = 24
            factory.applyFont()

            #expect(factory.shells[paneID]?.font.pointSize == 24)
            #expect(original != 24, "the test needs the size to actually change")
            factory.release(paneID)
        }
    }

    @Test("the theme reaches a live shell, opacity and all")
    func applyThemeReachesLiveShell() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            let (factory, paneID) = factoryWithOneShell()

            Preferences.terminalBackgroundOpacity = 0.75
            Preferences.themeMode = .light
            factory.apply(theme: Preferences.resolvedTheme())

            let shell = try! #require(factory.shells[paneID])
            #expect(!shell.spec.theme.isDark)
            #expect(abs(shell.spec.theme.backgroundOpacity - 0.75) < 0.0001)
            // The COLOURS reach the terminal; the opacity does not, and must not — see
            // `terminalPaintsNoBackgroundOfItsOwn`.
            #expect(shell.nativeForegroundColor.usingColorSpace(.sRGB)?.brightnessComponent
                    ?? 1 < 0.5, "a light theme is dark text")
            factory.release(paneID)
        }
    }

    /// The pane paints the background, ONCE, for every kind of pane. This is the assertion
    /// that stops the double-composite coming back: the wrapper filled the padding and
    /// SwiftTerm filled the grid, both translucent, so a terminal at 50% showed 50% in its
    /// margins and 75% behind its text — a visible frame of its own background.
    @Test("the terminal paints no background of its own, at any opacity")
    func terminalPaintsNoBackgroundOfItsOwn() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            let (factory, paneID) = factoryWithOneShell()
            let shell = try! #require(factory.shells[paneID])

            for opacity in [CGFloat(0), 0.5, 1] {
                Preferences.terminalBackgroundOpacity = opacity
                factory.apply(theme: Preferences.resolvedTheme())
                #expect(shell.nativeBackgroundColor.alphaComponent < 0.01,
                        "the pane's surface IS the shell's surface, at \(opacity)")
            }
            factory.release(paneID)
        }
    }

    /// The RGB still has to be right even though the alpha is zero: SwiftTerm hands it to
    /// the engine as `terminal.backgroundColor`, which is what reverse video draws with.
    @Test("the theme's background colour still reaches the terminal engine")
    func backgroundColourStillReachesTheEngine() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            let (factory, paneID) = factoryWithOneShell()

            Preferences.themeMode = .light
            factory.apply(theme: Preferences.resolvedTheme())
            let shell = try! #require(factory.shells[paneID])
            let light = try! #require(shell.nativeBackgroundColor.usingColorSpace(.sRGB))
            #expect(light.brightnessComponent > 0.8, "a light theme is a light background")

            Preferences.themeMode = .dark
            factory.apply(theme: Preferences.resolvedTheme())
            let dark = try! #require(shell.nativeBackgroundColor.usingColorSpace(.sRGB))
            #expect(dark.brightnessComponent < 0.2, "a dark theme is a dark background")
            factory.release(paneID)
        }
    }

    @Test("applying the same font twice does not churn every shell")
    func applyFontIsIdempotent() {
        let name = "ultra.tests.apply.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
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
}
