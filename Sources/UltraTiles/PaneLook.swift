import AppKit
import UltraCore

/// The sun-and-moon switch an editor or a chat pane wears: the OTHER look from the app's.
///
/// It was "pin light", which in a dark app is the other look and in a light app is nothing
/// at all — the switch did not visibly do anything. Pinned to whichever look the app is not
/// wearing, it does the same thing in both: a pane that stands apart from the window. Still
/// a plain light or dark on the record, so a pane comes back as it was left whatever the
/// app is wearing by then. The browser's switch is its page's mode instead, always one or
/// the other, and is not this.
public enum PaneLook {
    /// Whether the app is wearing dark: the window's look, which a pane's pin does not move.
    @MainActor public static var appIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// What a pin becomes when switched: unpinned when it was pinned, else the other look.
    public static func toggled(_ pinned: PaneRecord.Appearance?, appIsDark: Bool) -> PaneRecord.Appearance? {
        pinned != nil ? nil : (appIsDark ? .light : .dark)
    }

    /// The switch's symbol: the look a click leads to, as the sun or the moon.
    public static func symbol(_ pinned: PaneRecord.Appearance?, appIsDark: Bool) -> String {
        let next = toggled(pinned, appIsDark: appIsDark) ?? (appIsDark ? .dark : .light)
        return next == .light ? "sun.max" : "moon"
    }

    /// The switch's tooltip, naming the pane — "Editor", "Chat".
    public static func help(_ pinned: PaneRecord.Appearance?, appIsDark: Bool, pane: String) -> String {
        if pinned != nil { return "Follow the App's Appearance (⌃⌘L)" }
        return "Show \(pane) \(appIsDark ? "Light" : "Dark") (⌃⌘L)"
    }
}
