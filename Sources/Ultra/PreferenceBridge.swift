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
    private static var systemAppearanceObserver: NSObjectProtocol?

    /// Idempotent — every window calls it, one observer runs.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { apply() }
            }
        // Follow System has no preference write to hang off: the OS changes underneath a
        // setting that never moved. Distributed, because the appearance switch is a
        // system-wide event rather than one this process took part in.
        //
        // Deferred by a turn of the run loop on purpose — the notification arrives while
        // `AppleInterfaceStyle` is still being written, so reading it now returns the value
        // that is on its way out.
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard Preferences.themeMode == .system else { return }
                    DispatchQueue.main.async { apply() }
                }
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
        // The appearance FIRST, and from the mode rather than from the theme. Everything
        // resolved below — the tokens, the glass, every dynamic `NSColor` — reads the
        // appearance that is current when it is asked, so setting it afterwards leaves one
        // repaint's worth of the old theme's colours on screen.
        syncAppAppearance()

        let theme = Preferences.resolvedTheme()
        for factory in ShellWorkspace.Registry.factories.values {
            factory.applyFont()
            factory.apply(theme: theme)
            factory.applyRenderer()
        }
        // The CANVAS, not only the shells. The window's pinned appearance, every pane's
        // surface and every focus ring are all downstream of `LayoutStore.theme`, and it
        // was written once at construction and never again — so changing the theme moved
        // the terminal text and left the entire window around it alone, which is what
        // "changing the theme does nothing" actually was.
        for store in ShellWorkspace.Registry.stores.values {
            store.theme = theme
            // The gutter is the one look setting the LAYOUT owns rather than a view: it is
            // what decides how much of the window's material is visible between panes, so
            // changing it has to re-run the layout, not just repaint.
            if store.metrics.gutter != Appearance.paneGutter {
                store.metrics.gutter = Appearance.paneGutter
            }
            // A CGColor on a layer, set once: the accent reaches a live pane only if it is
            // pushed. Cheap and idempotent, so it rides along with every write.
            store.surfaces.refreshChrome()
        }
    }

    /// Pin — or deliberately unpin — the app's appearance.
    ///
    /// Guarded on a real change: assigning `NSApp.appearance` walks every window and forces
    /// a full redraw, and doing that on every preference write is visible as a flicker.
    static func syncAppAppearance() {
        let wanted = Preferences.appAppearance
        // Compared by NAME, not by identity: `NSAppearance(named:)` is not documented to
        // vend a shared instance, and an identity check that is always false is a guard
        // that never guards.
        guard NSApp.appearance?.name != wanted?.name else { return }
        NSApp.appearance = wanted
    }
}
