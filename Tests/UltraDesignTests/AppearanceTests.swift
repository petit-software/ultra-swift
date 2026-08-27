import Testing
import AppKit
import Foundation
@testable import UltraDesign

/// An isolated domain per call — see `PreferencesTests` for why this is bound rather than
/// assigned.
private func clean(_ body: () -> Void) {
    let name = "ultra.tests.appearance.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    Preferences.withStore(suite, body)
}

/// The look is a set of numbers now, and the promise those numbers make is that **today's
/// value is the default**. These hold the app to it.
@Suite("Appearance", .serialized)
struct AppearanceTests {

    @Test("an untouched install looks exactly like the constants it replaced")
    func defaultsAreTheShippedLook() {
        clean {
            #expect(Appearance.glassStyle == .regular)
            #expect(Appearance.glassTint == .off)
            #expect(Appearance.glassTintStrength == 0.20)
            #expect(Appearance.mergesPaneGlass == false)
            #expect(Appearance.glassMergeSpacing == 0)

            #expect(Appearance.paneRadius == 18)
            #expect(Appearance.paneShadowRadius == 10)
            #expect(Appearance.paneShadowOpacity == 0.28)
            #expect(Appearance.paneGutter == 12)
            #expect(Appearance.focusRingWidth == 2)
            #expect(Appearance.focusRingStrength == 0.25)

            #expect(Appearance.windowMaterial == .underWindowBackground)
            #expect(Appearance.windowTintDark == 0.30)
            #expect(Appearance.windowTintLight == 0.45)
            #expect(Appearance.windowRadius == 24)
            #expect(Appearance.windowBorderWidth == 1.5)
            #expect(Appearance.windowBorderStrength == 0.22)

            #expect(Appearance.headerBlurRadius == 14)
            #expect(Appearance.headerTintOpacity == 0.28)
        }
    }

    /// The tokens are the only thing the app draws with, so a setting the tokens do not read
    /// is a control that does nothing.
    @Test("the tokens read the settings")
    func tokensFollowTheSettings() {
        clean {
            Appearance.paneRadius = 4
            Appearance.paneGutter = 30
            Appearance.focusRingWidth = 5
            Appearance.paneShadowRadius = 2
            Appearance.paneShadowOpacity = 0.9
            Appearance.windowRadius = 40
            Appearance.windowBorderWidth = 3
            Appearance.headerBlurRadius = 25
            Appearance.headerTintOpacity = 0.5
            Appearance.focusRingStrength = 0.75

            #expect(Token.Space.paneRadius == 4)
            #expect(Token.Space.gutter == 30)
            #expect(Token.Space.focusRingWidth == 5)
            #expect(Token.Space.paneShadowRadius == 2)
            #expect(abs(Token.Space.paneShadowOpacity - 0.9) < 0.0001)
            #expect(Token.Space.windowRadius == 40)
            #expect(Token.Space.windowBorderWidth == 3)
            #expect(Token.Space.headerBlurRadius == 25)
            #expect(Token.Space.headerTintOpacity == 0.5)
            #expect(abs(Token.Colour.accentMutedStrength - 0.75) < 0.0001)
        }
    }

    /// AppKit masks a titled window to 15.5pt. A radius below that draws a second arc inside
    /// the system's own, which is the doubled-corner glitch — so the control must not be able
    /// to reach it, whatever arrives through `defaults write`.
    @Test("the window radius cannot go under the system's mask")
    func windowRadiusCannotUndercutTheMask() {
        clean {
            Appearance.windowRadius = 0
            #expect(Appearance.windowRadius == Token.Space.systemWindowRadius)

            // Clamped on READ as well, for a value that never passed through the control.
            Preferences.store.set(2.0, forKey: "appearance.windowRadius")
            #expect(Appearance.windowRadius == Token.Space.systemWindowRadius)
        }
    }

    @Test("values are clamped to their range on the way in and on the way out")
    func clamping() {
        clean {
            Appearance.paneRadius = 500
            #expect(Appearance.paneRadius == 36)
            Appearance.glassTintStrength = -1
            #expect(Appearance.glassTintStrength == 0)

            Preferences.store.set(99.0, forKey: "appearance.headerTintOpacity")
            #expect(Appearance.headerTintOpacity == 1)
        }
    }

    /// A knob `reset()` cannot reach is a knob "Reset to Defaults" quietly lies about. The
    /// list is written by hand, so something has to notice when the next one is added
    /// without it — this reads every property, writes a non-default into every key, and
    /// checks the defaults come back.
    @Test("reset reaches every setting there is")
    func resetReachesEverything() {
        clean {
            Appearance.glassStyle = .clear
            Appearance.glassTint = .accent
            Appearance.glassTintStrength = 0.5
            Appearance.mergesPaneGlass = true
            Appearance.glassMergeSpacing = 40
            Appearance.paneRadius = 2
            Appearance.paneShadowRadius = 30
            Appearance.paneShadowOpacity = 0.9
            Appearance.paneGutter = 36
            Appearance.focusRingWidth = 6
            Appearance.focusRingStrength = 0.9
            Appearance.windowMaterial = .hudWindow
            Appearance.windowTintDark = 0.9
            Appearance.windowTintLight = 0.1
            Appearance.windowRadius = 40
            Appearance.windowBorderWidth = 4
            Appearance.windowBorderStrength = 0.9
            Appearance.headerBlurRadius = 35
            Appearance.headerTintOpacity = 0.9

            // Every key this namespace owns now holds something.
            for name in Appearance.keys {
                #expect(Preferences.store.object(forKey: "appearance." + name) != nil,
                        "\(name) is in `keys` but nothing wrote it — is its setter using a different key?")
            }

            Appearance.reset()

            for name in Appearance.keys {
                #expect(Preferences.store.object(forKey: "appearance." + name) == nil,
                        "\(name) survived a reset")
            }
            #expect(Appearance.glassStyle == .regular)
            #expect(Appearance.paneRadius == 18)
            #expect(Appearance.windowMaterial == .underWindowBackground)
        }
    }

    /// The general Reset button has to take the look with it: resetting everything except
    /// the thing someone was most likely experimenting with is the one case where it has to
    /// be right.
    @Test("resetting preferences resets the look too, and announces it once")
    func preferencesResetIncludesTheLook() {
        clean {
            Appearance.paneRadius = 2
            Preferences.terminalFontSize = 20

            var count = 0
            let token = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: Preferences.store,
                queue: nil) { _ in count += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            Preferences.reset()

            #expect(Appearance.paneRadius == 18)
            #expect(Preferences.terminalFontSize == 13)
            #expect(count == 1, "one reset is one announcement, not one per namespace")
        }
    }

    @Test("a look change announces on the same channel a preference does")
    func changesAnnounce() {
        clean {
            var count = 0
            let token = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: Preferences.store,
                queue: nil) { _ in count += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            Appearance.paneRadius = 20
            #expect(count == 1)
            Appearance.paneRadius = 20
            #expect(count == 1, "a no-op must not wake every view in the app")
            Appearance.glassStyle = .clear
            #expect(count == 2)
            Appearance.glassStyle = .clear
            #expect(count == 2)
        }
    }

    @Test("the window tint follows both amounts, and lifts in light appearance")
    func windowTintFollowsAppearance() {
        clean {
            Appearance.windowTintDark = 0.5
            Appearance.windowTintLight = 0.8

            let tint = Token.Colour.windowTint
            let dark = tint.withAppearance(.darkAqua)
            let light = tint.withAppearance(.aqua)

            #expect(abs(dark.alphaComponent - 0.5) < 0.01)
            #expect(abs(light.alphaComponent - 0.8) < 0.01)
            #expect(dark.brightnessComponent < 0.1, "dark appearance smokes with black")
            #expect(light.brightnessComponent > 0.9, "light appearance lifts with white")
        }
    }
}

private extension NSColor {
    /// Resolve a dynamic colour against a named appearance. `usingColorSpace` is where the
    /// resolution happens, and it reads whichever appearance is current.
    func withAppearance(_ name: NSAppearance.Name) -> NSColor {
        var resolved = self
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }
}
