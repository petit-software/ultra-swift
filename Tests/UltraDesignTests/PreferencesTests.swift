import Testing
import AppKit
import Foundation
@testable import UltraDesign

/// See `AppearanceTests` — an isolated domain per call, so suites cannot stomp each other.
private func clean(_ body: () -> Void) {
    let name = "ultra.tests.preferences.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    let previous = Preferences.store
    Preferences.store = suite
    defer {
        Preferences.store = previous
        suite.removePersistentDomain(forName: name)
    }
    body()
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
}
