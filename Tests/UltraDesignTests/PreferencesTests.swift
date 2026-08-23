import Testing
import AppKit
import SwiftUI
import Foundation
@testable import UltraDesign

/// See `AppearanceTests` — an isolated domain per call, so suites cannot stomp each other.
/// Runs `body` against a suite of its own.
///
/// Bound rather than assigned. Assigning a global worked until a second test TARGET did the
/// same thing in the same process, at which point the two swapped the store out from under
/// each other and three different suites started failing about one run in three.
private func clean(_ body: () -> Void) {
    let name = "ultra.tests.preferences.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    Preferences.withStore(suite, body)
}

@Suite("Preferences", .serialized)
struct PreferencesTests {

    @Test("an untouched install reads today's behaviour")
    func defaults() {
        clean {
            #expect(Preferences.terminalFontSize == 13)
            #expect(Preferences.terminalBackgroundOpacity == 0)
            #expect(Preferences.themeMode == .dark)
            #expect(Preferences.showsHiddenFiles)
            #expect(Preferences.portsInterval == 2)
            #expect(Preferences.resourcesInterval == 2)
            #expect(Preferences.gitInterval == 3)
            #expect(Preferences.pausePollingWhenOccluded)
            #expect(Preferences.defaultTodoPath == ".ultra/todo.md")
        }
    }

    @Test("values round-trip and reset")
    func roundTrip() {
        clean {
            Preferences.terminalFontSize = 18
            Preferences.themeMode = .light
            Preferences.showsHiddenFiles = false
            #expect(Preferences.terminalFontSize == 18)
            #expect(Preferences.themeMode == .light)
            #expect(!Preferences.showsHiddenFiles)

            Preferences.reset()
            #expect(Preferences.terminalFontSize == 13)
            #expect(Preferences.themeMode == .dark)
            #expect(Preferences.showsHiddenFiles)
        }
    }

    /// Same reasoning as `Appearance`: a value can arrive from an older build or
    /// `defaults write` without ever passing through the control that bounds it.
    @Test("numbers are clamped reading as well as writing")
    func clamping() {
        clean {
            Preferences.terminalFontSize = 900
            #expect(Preferences.terminalFontSize == 32)
            Preferences.terminalFontSize = 1
            #expect(Preferences.terminalFontSize == 8)

            Preferences.store.set(-40.0, forKey: "preference.gitInterval")
            #expect(Preferences.gitInterval == 1, "a stored value must be clamped on read")

            Preferences.store.set(2.0, forKey: "preference.terminalBackgroundOpacity")
            #expect(Preferences.terminalBackgroundOpacity == 1)
        }
    }

    @Test("a poll interval can never reach zero and spin")
    func intervalsHaveAFloor() {
        clean {
            for write in [0.0, -1.0, 0.001] {
                Preferences.store.set(write, forKey: "preference.portsInterval")
                #expect(Preferences.portsInterval >= 1,
                        "\(write) produced \(Preferences.portsInterval) — a busy loop over lsof")
            }
        }
    }

    @Test("the theme carries the background opacity, so a shell's surface follows it")
    @MainActor
    func themeCarriesOpacity() {
        clean {
            Preferences.terminalBackgroundOpacity = 0.6
            #expect(abs(Preferences.resolvedTheme().backgroundOpacity - 0.6) < 0.0001)
            Preferences.themeMode = .light
            #expect(!Preferences.resolvedTheme().isDark)
            #expect(abs(Preferences.resolvedTheme().backgroundOpacity - 0.6) < 0.0001)
        }
    }

    /// Pinning the window's appearance to a theme that was DERIVED from the window's
    /// appearance is a loop that never notices the system changing.
    @Test("Follow System does not pin the window appearance")
    func systemModeDoesNotPin() {
        clean {
            Preferences.themeMode = .dark
            #expect(Preferences.pinsWindowAppearance)
            Preferences.themeMode = .light
            #expect(Preferences.pinsWindowAppearance)
            Preferences.themeMode = .system
            #expect(!Preferences.pinsWindowAppearance)
        }
    }

    @Test("the terminal font follows the size setting")
    func font() {
        clean {
            Preferences.terminalFontSize = 20
            #expect(Preferences.terminalFont.pointSize == 20)
            #expect(Preferences.terminalFont.isFixedPitch, "a terminal grid needs a mono font")
        }
    }

    @Test("an empty path falls back rather than pointing at nothing")
    func emptyPathFallsBack() {
        clean {
            Preferences.defaultTodoPath = "   "
            #expect(Preferences.defaultTodoPath == ".ultra/todo.md")
            Preferences.defaultTodoPath = "docs/TODO.md"
            #expect(Preferences.defaultTodoPath == "docs/TODO.md")
        }
    }

    @Test("a change notifies once, a no-op not at all")
    func notifies() {
        clean {
            var count = 0
            let token = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: nil, queue: nil) { _ in count += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            Preferences.terminalFontSize = 16
            #expect(count == 1)
            Preferences.terminalFontSize = 16
            #expect(count == 1)
            Preferences.showsHiddenFiles = false
            #expect(count == 2)
            Preferences.showsHiddenFiles = false
            #expect(count == 2)
        }
    }


    @Test("the default is white")
    func defaultIsWhite() {
        clean { #expect(Preferences.accentColour == .white) }
    }

    @Test("the accent choice round-trips and resets")
    func accentRoundTrip() {
        clean {
            Preferences.accentColour = .purple
            #expect(Preferences.accentColour == .purple)
            Preferences.reset()
            #expect(Preferences.accentColour == .white)
        }
    }

    /// The point of the setting: ONE value drives every tinted thing. If a variation stops
    /// deriving from `accent`, this is what catches it.
    @Test("every derived tint follows the accent")
    func derivationsFollow() {
        clean {
            func components(_ colour: Color) -> (Double, Double, Double, Double) {
                let ns = NSColor(colour).usingColorSpace(.sRGB)!
                return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
            }
            Preferences.accentColour = .red
            let red = components(Token.Colour.accent)
            #expect(red.0 > 0.5 && red.2 < 0.5)
            #expect(components(Token.Colour.focusBorder).0 == red.0,
                    "the focus ring must be the accent, not a second colour")
            // The washes are the accent at a lower alpha, not a different hue.
            func dominantChannel(_ c: (Double, Double, Double, Double)) -> Int {
                c.0 >= c.1 && c.0 >= c.2 ? 0 : (c.1 >= c.2 ? 1 : 2)
            }
            for wash in [Token.Colour.accentWash, Token.Colour.accentWashStrong] {
                let c = components(wash)
                #expect(dominantChannel(c) == dominantChannel(red),
                        "a wash must be the accent's hue, not a different colour")
                #expect(c.3 < 0.5, "a wash is a background, so it stays translucent")
            }
            #expect(components(Token.Colour.accentWashStrong).3
                    > components(Token.Colour.accentWash).3,
                    "the active target must read stronger than a resting one")

            Preferences.accentColour = .green
            let green = components(Token.Colour.accent)
            #expect(green.1 > red.1, "changing the accent changed the derived value too")
            #expect(dominantChannel(components(Token.Colour.accentWash)) == dominantChannel(green))
        }
    }

    @Test("changing the accent notifies once")
    func accentNotifies() {
        clean {
            var count = 0
            // Scoped to THIS suite's store. `object: nil` means "any sender", so this
            // counted preference changes made by every other test target sharing the
            // process — a one-in-ten miscount that looked like a broken assertion.
            let token = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: Preferences.store, queue: nil) { _ in
                    count += 1
                }
            defer { NotificationCenter.default.removeObserver(token) }
            Preferences.accentColour = .teal
            Preferences.accentColour = .teal
            #expect(count == 1)
        }
    }

    @Test("every choice offers a title and a colour")
    func allChoicesAreUsable() {
        for choice in Preferences.AccentColour.allCases {
            #expect(!choice.title.isEmpty)
            #expect(NSColor(choice.color).usingColorSpace(.sRGB) != nil,
                    "\(choice.rawValue) has no renderable colour")
        }
    }
}
