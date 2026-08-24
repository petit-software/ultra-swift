import AppKit
import Foundation
import UltraDesign
import UltraTerminal

/// Pushes preference changes to the shells that are already running.
///
/// This existed only in the test suite. `ShellPaneFactory.applyFont()` and `apply(theme:)`
/// were both built, both covered by tests asserting they reach a live shell — and nothing in
/// the app ever called either one. So changing the font size or the theme in Settings took
/// effect for panes opened AFTERWARDS and left every pane already on screen alone, which
/// reads as the setting being broken rather than as it being deferred.
///
/// The tests were not wrong, and this is the useful lesson: they proved the factory's reach,
/// which is exactly what they claim to prove. Nothing asserted that the app was holding the
/// other end. One notification observer covers every live-applicable preference at once, so
/// the next one added does not need to remember to find this file.
@MainActor
enum PreferenceBridge {
    private static var observer: NSObjectProtocol?
    private static var terminationObserver: NSObjectProtocol?

    /// Idempotent — every window calls it, one observer runs.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { apply() }
            }
        // ⌘Q does not reliably run a window's `onDisappear`, so the save that hangs off it
        // covers closing a window and not quitting the app — which is the more common way
        // this one ends, and the moment there is most history worth keeping.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for factory in ShellWorkspace.Registry.factories.values {
                        factory.saveScrollback()
                    }
                }
            }
    }

    /// Bring every live shell in every tab in line with the current settings.
    ///
    /// Each `apply*` is individually idempotent — the font one skips shells already at the
    /// size, the renderer one skips shells already in the right mode — which matters because
    /// this fires on EVERY preference write, including ones no shell cares about.
    static func apply() {
        let theme = Preferences.resolvedTheme()
        for factory in ShellWorkspace.Registry.factories.values {
            factory.applyFont()
            factory.apply(theme: theme)
            factory.applyRenderer()
        }
    }
}
