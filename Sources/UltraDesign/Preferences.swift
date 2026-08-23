import AppKit
import Foundation
import SwiftUI

/// Settings that change how the app *works*, as opposed to how it looks.
///
/// Same shape as `Appearance` and for the same reason: today's constants become the
/// defaults, the call sites read through here, and nothing else changes.
public enum Preferences {

    public enum ThemeMode: String, CaseIterable, Sendable, Identifiable {
        case dark, light, system
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .dark: "Dark"
            case .light: "Light"
            case .system: "Follow System"
            }
        }
    }

    /// The one colour the app is tinted with.
    ///
    /// Everything tinted derives from this single value — focus borders, checkboxes, drop
    /// targets, the washes behind selected rows — so changing it here changes all of them.
    /// There is no second accent anywhere to fall out of step.
    public enum AccentColour: String, CaseIterable, Sendable, Identifiable {
        case white, system, blue, teal, green, yellow, orange, red, pink, purple
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .white: "White"
            case .system: "System Accent"
            default: rawValue.capitalized
            }
        }

        public var color: Color {
            switch self {
            case .white: .white
            case .system: Color(nsColor: .controlAccentColor)
            case .blue: Color(nsColor: .systemBlue)
            case .teal: Color(nsColor: .systemTeal)
            case .green: Color(nsColor: .systemGreen)
            case .yellow: Color(nsColor: .systemYellow)
            case .orange: Color(nsColor: .systemOrange)
            case .red: Color(nsColor: .systemRed)
            case .pink: Color(nsColor: .systemPink)
            case .purple: Color(nsColor: .systemPurple)
            }
        }
    }

    public static var accentColour: AccentColour {
        get {
            store.string(forKey: prefix + "accentColour")
                .flatMap(AccentColour.init(rawValue:)) ?? .white
        }
        set {
            guard newValue != accentColour else { return }
            store.set(newValue.rawValue, forKey: prefix + "accentColour")
            post()
        }
    }

    public static let didChange = Notification.Name("com.ultra.preferences.didChange")
    private static let prefix = "preference."

    /// Injectable so tests can use an isolated suite; two suites mutating the same keys
    /// in `.standard` is a genuine flake, not a theoretical one.
    public nonisolated(unsafe) static var store: UserDefaults = .standard

    // MARK: - Values

    /// Point size of the terminal grid. Ranges chosen so the extremes are still a usable
    /// terminal rather than a novelty.
    public static var terminalFontSize: CGFloat {
        get { number("terminalFontSize", default: 13, in: 8...32) }
        set { setNumber("terminalFontSize", newValue, current: terminalFontSize, in: 8...32) }
    }

    /// How opaque a shell's own background is. 0 means the pane's glass IS the shell's
    /// surface — which is the current design, and the reason a shell's header has nothing
    /// but the desktop to blur.
    public static var terminalBackgroundOpacity: CGFloat {
        get { number("terminalBackgroundOpacity", default: 0, in: 0...1) }
        set { setNumber("terminalBackgroundOpacity", newValue, current: terminalBackgroundOpacity, in: 0...1) }
    }

    public static var themeMode: ThemeMode {
        get {
            store.string(forKey: prefix + "themeMode")
                .flatMap(ThemeMode.init(rawValue:)) ?? .dark
        }
        set {
            guard newValue != themeMode else { return }
            store.set(newValue.rawValue, forKey: prefix + "themeMode")
            post()
        }
    }

    public static var showsHiddenFiles: Bool {
        get { flag("showsHiddenFiles", default: true) }
        set { setFlag("showsHiddenFiles", newValue, current: showsHiddenFiles) }
    }

    /// Seconds between refreshes. Each tile shells out to a real command, so these are the
    /// difference between a live readout and a laptop that never idles.
    public static var portsInterval: CGFloat {
        get { number("portsInterval", default: 2, in: 1...30) }
        set { setNumber("portsInterval", newValue, current: portsInterval, in: 1...30) }
    }

    public static var resourcesInterval: CGFloat {
        get { number("resourcesInterval", default: 2, in: 1...30) }
        set { setNumber("resourcesInterval", newValue, current: resourcesInterval, in: 1...30) }
    }

    public static var gitInterval: CGFloat {
        get { number("gitInterval", default: 3, in: 1...60) }
        set { setNumber("gitInterval", newValue, current: gitInterval, in: 1...60) }
    }

    /// A tile polling behind a hidden window burns battery to update pixels nobody can see.
    public static var pausePollingWhenOccluded: Bool {
        get { flag("pausePollingWhenOccluded", default: true) }
        set { setFlag("pausePollingWhenOccluded", newValue, current: pausePollingWhenOccluded) }
    }

    /// The path a project's Todo file takes when it has not been chosen explicitly.
    /// Relative to the project root; per-project choices still win.
    public static var defaultTodoPath: String {
        get { string("defaultTodoPath", default: ".ultra/todo.md") }
        set { setString("defaultTodoPath", newValue, current: defaultTodoPath) }
    }

    public static var defaultContextPath: String {
        get { string("defaultContextPath", default: ".ultra/context.json") }
        set { setString("defaultContextPath", newValue, current: defaultContextPath) }
    }

    // MARK: - Resolved

    /// The theme to use right now. In `.system` the app follows the OS rather than pinning
    /// the window, so switching appearance in System Settings is reflected without a relaunch.
    @MainActor
    public static func resolvedTheme() -> TerminalTheme {
        var theme: TerminalTheme
        switch themeMode {
        case .dark: theme = .dark
        case .light: theme = .light
        case .system:
            let isDark = NSApp?.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            theme = isDark ? .dark : .light
        }
        theme.backgroundOpacity = terminalBackgroundOpacity
        return theme
    }

    /// Whether the window's appearance should be pinned. In `.system` it must not be —
    /// pinning it to a theme derived from the system appearance is a loop that never
    /// notices the system changing.
    public static var pinsWindowAppearance: Bool { themeMode != .system }

    public static var terminalFont: NSFont {
        .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
    }

    // MARK: - Storage

    public static func reset() {
        for key in ["accentColour", "terminalFontSize", "terminalBackgroundOpacity", "themeMode",
                    "showsHiddenFiles", "portsInterval", "resourcesInterval", "gitInterval",
                    "pausePollingWhenOccluded", "defaultTodoPath", "defaultContextPath"] {
            store.removeObject(forKey: prefix + key)
        }
        post()
    }

    /// Announced WITH the store that changed.
    ///
    /// Posting `object: nil` made every observer a global one, because nil on the receiving
    /// side means "any sender" — so a suite watching its own isolated store also counted
    /// changes made by every other test target in the process. That presents as a
    /// count-off-by-one about one run in ten, which reads like a broken assertion rather
    /// than like a race. The app has one store and observes with nil, so nothing changes
    /// there; anyone who needs to care now can.
    private static func post() {
        NotificationCenter.default.post(name: didChange, object: store)
    }

    /// Clamped on read as well as write — the same reasoning as `Appearance`: a value that
    /// arrived through `defaults write` or an older build never passed through the control.
    private static func number(_ key: String, default fallback: CGFloat,
                               in range: ClosedRange<CGFloat>) -> CGFloat {
        guard let raw = store.object(forKey: prefix + key) as? Double
        else { return fallback }
        return min(max(CGFloat(raw), range.lowerBound), range.upperBound)
    }

    /// `current` is passed in rather than re-read with a sentinel default. A NaN sentinel
    /// looks natural here and is a trap: every comparison against NaN is false, so the
    /// no-op guard rejected every write and nothing could be set at all.
    private static func setNumber(_ key: String, _ value: CGFloat, current: CGFloat,
                                  in range: ClosedRange<CGFloat>) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard abs(clamped - current) > 0.0001 else { return }
        store.set(Double(clamped), forKey: prefix + key)
        post()
    }

    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        store.object(forKey: prefix + key) as? Bool ?? fallback
    }

    private static func setFlag(_ key: String, _ value: Bool, current: Bool) {
        guard value != current else { return }
        store.set(value, forKey: prefix + key)
        post()
    }

    private static func string(_ key: String, default fallback: String) -> String {
        let stored = store.string(forKey: prefix + key) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    private static func setString(_ key: String, _ value: String, current: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed != current else { return }
        store.set(trimmed, forKey: prefix + key)
        post()
    }
}

/// SwiftUI's view of the preferences, mirroring `AppearanceModel`.
@MainActor
@Observable
public final class PreferencesModel {
    public static let shared = PreferencesModel()
    public private(set) var revision = 0
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision &+= 1 }
            }
    }

    public func number(_ get: @escaping () -> CGFloat,
                       _ set: @escaping (CGFloat) -> Void) -> Binding<CGFloat> {
        Binding(get: { _ = self.revision; return get() }, set: set)
    }

    public func flag(_ get: @escaping () -> Bool,
                     _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { _ = self.revision; return get() }, set: set)
    }

    public func accent() -> Binding<Preferences.AccentColour> {
        Binding(get: { _ = self.revision; return Preferences.accentColour },
                set: { Preferences.accentColour = $0 })
    }

    public func theme() -> Binding<Preferences.ThemeMode> {
        Binding(get: { _ = self.revision; return Preferences.themeMode },
                set: { Preferences.themeMode = $0 })
    }

    public func text(_ get: @escaping () -> String,
                     _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { _ = self.revision; return get() }, set: set)
    }
}
