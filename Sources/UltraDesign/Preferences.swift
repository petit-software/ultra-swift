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

    /// Where preferences are read and written.
    ///
    /// TASK-LOCAL, not a mutable global. Tests need an isolated suite — two of them mutating
    /// the same keys in `.standard` is a genuine flake, not a theoretical one — and the
    /// obvious way to give them one is to assign this, run, and put it back. That works
    /// until two test TARGETS do it in the same process, at which point one swaps the store
    /// out from under the other mid-test. It presented as three different suites failing
    /// about one full run in three while every one of them passed in isolation, and it
    /// survived two fixes aimed at the suites rather than at the global.
    ///
    /// Bound with `Preferences.withStore(suite) { … }`, a swap now reaches only the task
    /// that made it. Production never binds it and reads `.standard`.
    public static var store: UserDefaults { boundStore.defaults }

    /// Run `body` with preferences read from and written to `defaults`.
    ///
    /// The binding covers this task and anything it awaits. It does NOT reach work handed to
    /// another executor and left to run later — such work sees `.standard`, which is the
    /// honest outcome: a task-local cannot follow a value somewhere its scope does not go.
    public static func withStore<T>(_ defaults: UserDefaults,
                                    _ body: () throws -> T) rethrows -> T {
        try $boundStore.withValue(BoundStore(defaults), operation: body)
    }

    @TaskLocal static var boundStore = BoundStore(.standard)

    /// `UserDefaults` declares its `Sendable` conformance UNAVAILABLE, so it cannot be a
    /// task-local value directly. It is documented as thread-safe, and this box carries it
    /// without claiming anything more than that — the unchecked conformance is about
    /// Foundation's annotation, not about a guarantee being waived.
    struct BoundStore: @unchecked Sendable {
        let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
    }

    // MARK: - Values

    /// Point size of the terminal grid. Ranges chosen so the extremes are still a usable
    /// terminal rather than a novelty.
    public static var terminalFontSize: CGFloat {
        get { number("terminalFontSize", default: 13, in: 8...32) }
        set { setNumber("terminalFontSize", newValue, current: terminalFontSize, in: 8...32) }
    }

    /// How opaque a PANE's own background is. 0 means the pane's glass IS its surface —
    /// which is the current design, and the reason a pane's header has nothing but the
    /// desktop to blur.
    ///
    /// Named for the terminal because that is where it started, and it is the stored key —
    /// renaming it would silently reset the setting for everyone who has one. What changed
    /// is its REACH: it used to be painted only under shells, so a window of a shell and
    /// three tiles answered the slider on one pane out of four.
    public static var terminalBackgroundOpacity: CGFloat {
        get { number("terminalBackgroundOpacity", default: 0, in: 0...1) }
        set { setNumber("terminalBackgroundOpacity", newValue, current: terminalBackgroundOpacity, in: 0...1) }
    }

    /// Show Ultra in the menu bar.
    ///
    /// On by default: it is the only place the app can say something while its windows are
    /// closed or behind everything else, which is exactly when an agent is running.
    public static var showsMenuBarIcon: Bool {
        get { store.object(forKey: prefix + "showsMenuBarIcon") as? Bool ?? true }
        set {
            guard newValue != showsMenuBarIcon else { return }
            store.set(newValue, forKey: prefix + "showsMenuBarIcon")
            post()
        }
    }

    /// Notify when a long-running agent finishes.
    ///
    /// Off by default, and deliberately so: turning it on is what asks macOS for permission
    /// to post notifications, and an app that raises that prompt on first launch for a
    /// feature nobody asked for has spent the user's goodwill on a guess.
    public static var notifiesOnAgentCompletion: Bool {
        get { store.object(forKey: prefix + "notifiesOnAgentCompletion") as? Bool ?? false }
        set {
            guard newValue != notifiesOnAgentCompletion else { return }
            store.set(newValue, forKey: prefix + "notifiesOnAgentCompletion")
            post()
        }
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

    /// Let a shell ring the system alert with `BEL`.
    ///
    /// OFF, which is the opposite of every other terminal's default, and the reason is what
    /// this app is FOR. An agent uses `BEL` as a progress signal — it rings on a tool call,
    /// on a permission prompt, on finishing a turn — so a pane running one does not go
    /// "ding" occasionally, it goes "ding" continuously, and a window of four agent panes
    /// does it four times over. A terminal built to hold agents cannot ship the default a
    /// terminal built to hold a shell prompt gets away with.
    ///
    /// Nothing else about the bell changes: the escape is still parsed, and turning this on
    /// gives the ordinary Terminal.app behaviour back.
    public static var audibleBell: Bool {
        get { flag("audibleBell", default: false) }
        set { setFlag("audibleBell", newValue, current: audibleBell) }
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

    /// Draw terminals on the GPU.
    ///
    /// OFF by default, and opt-in rather than opt-out on purpose. SwiftTerm ships the Metal
    /// path disabled too, and `setUseMetal(_:)` THROWS — a machine with no usable Metal
    /// device, or a pipeline that fails to build, is a real outcome rather than a
    /// hypothetical. A default that can fail at launch is a default that can make the app
    /// look broken for reasons the user did not choose, so this is something they turn on.
    ///
    /// The failure is not silent either way: see `ShellPaneFactory.applyRenderer()`, which
    /// falls back to CoreGraphics and says so in the pane rather than leaving a blank one.
    public static var useMetalRenderer: Bool {
        get { flag("useMetalRenderer", default: false) }
        set { setFlag("useMetalRenderer", newValue, current: useMetalRenderer) }
    }

    /// A tile polling behind a hidden window burns battery to update pixels nobody can see.
    public static var pausePollingWhenOccluded: Bool {
        get { flag("pausePollingWhenOccluded", default: true) }
        set { setFlag("pausePollingWhenOccluded", newValue, current: pausePollingWhenOccluded) }
    }

    /// The folder new windows open on, when the launch itself has no opinion.
    ///
    /// Empty by default, which means "keep guessing" — the most recent project, then home.
    /// That guess is right until the recents stop changing, and then it is wrong every
    /// single launch, which is the whole reason this exists: one project stays at the front
    /// of the list forever and the app opens there whatever the user is actually doing.
    ///
    /// Stored as a plain path rather than a bookmark. Ultra is unsandboxed, so it can open
    /// the folder without one, and a path is legible in `defaults read` and survives being
    /// edited by hand — a security-scoped bookmark is neither.
    public static var defaultProjectFolder: String {
        get { store.string(forKey: prefix + "defaultProjectFolder") ?? "" }
        set { setString("defaultProjectFolder", newValue, current: defaultProjectFolder) }
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
        case .system: theme = systemPrefersDark ? .dark : .light
        }
        theme.backgroundOpacity = terminalBackgroundOpacity
        return theme
    }

    /// Whether macOS ITSELF is in dark mode.
    ///
    /// Read from the system-wide `AppleInterfaceStyle`, deliberately NOT from
    /// `NSApp.effectiveAppearance`. The app PINS its own appearance in the other two modes,
    /// so asking the app hands back whatever we last wrote: switching from Dark to Follow
    /// System on a light Mac resolved "dark", the chrome unpinned to light, and the window
    /// ended up wearing two appearances at once. That is the glitch, and it is not a race —
    /// it happens every time, because the question was being put to the wrong object.
    ///
    /// `.standard` rather than `store`: this is a system key, and a test suite pointing
    /// preferences at its own domain has not moved the Mac into light mode.
    public static var systemPrefersDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?
            .lowercased().contains("dark") ?? false
    }

    /// The appearance the app should wear, or nil in Follow System where it must wear none.
    @MainActor
    public static var appAppearance: NSAppearance? {
        switch themeMode {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }

    /// Whether the window's appearance should be pinned. In `.system` it must not be —
    /// pinning it to a theme derived from the system appearance is a loop that never
    /// notices the system changing.
    ///
    /// The same rule `appAppearance` states by returning nil; this is the question asked
    /// without needing the main actor to answer it.
    public static var pinsWindowAppearance: Bool { themeMode != .system }

    public static var terminalFont: NSFont {
        .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
    }

    // MARK: - Storage

    public static func reset() {
        for key in ["accentColour", "terminalFontSize", "terminalBackgroundOpacity", "themeMode",
                    "notifiesOnAgentCompletion", "showsMenuBarIcon", "audibleBell",
                    "showsHiddenFiles", "portsInterval", "resourcesInterval", "gitInterval",
                    "pausePollingWhenOccluded", "defaultTodoPath", "defaultContextPath",
                    "defaultProjectFolder"] {
            store.removeObject(forKey: prefix + key)
        }
        // The look is a preference too. Resetting everything except the thing the user was
        // most likely experimenting with is the one case where this button has to be right.
        // `clear()` rather than `reset()`: one reset is one announcement.
        Appearance.clear()
        post()
    }

    /// Thin wrappers over `PreferenceStore`, which holds the one implementation. They exist
    /// only to save every property in this file repeating the key prefix.
    private static func post() { PreferenceStore.post() }

    private static func number(_ key: String, default fallback: CGFloat,
                               in range: ClosedRange<CGFloat>) -> CGFloat {
        PreferenceStore.number(prefix + key, default: fallback, in: range)
    }

    private static func setNumber(_ key: String, _ value: CGFloat, current: CGFloat,
                                  in range: ClosedRange<CGFloat>) {
        PreferenceStore.setNumber(prefix + key, value, current: current, in: range)
    }

    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        PreferenceStore.flag(prefix + key, default: fallback)
    }

    private static func setFlag(_ key: String, _ value: Bool, current: Bool) {
        PreferenceStore.setFlag(prefix + key, value, current: current)
    }

    private static func string(_ key: String, default fallback: String) -> String {
        PreferenceStore.string(prefix + key, default: fallback)
    }

    private static func setString(_ key: String, _ value: String, current: String) {
        PreferenceStore.setString(prefix + key, value, current: current)
    }
}

/// The one implementation of reading and writing a setting.
///
/// Shared by `Preferences` and `Appearance` rather than written twice. Two copies of
/// "clamped on read as well as write" is two copies that can disagree, and the read clamp is
/// the half that is easy to forget — it is what protects the app from a value that arrived
/// through `defaults write` or from an older build and never passed through a control.
///
/// Keys arrive fully qualified. Each namespace owns its own prefix, and a storage layer that
/// also owned one could only ever own the wrong one.
enum PreferenceStore {

    /// Announced WITH the store that changed.
    ///
    /// Posting `object: nil` made every observer a global one, because nil on the receiving
    /// side means "any sender" — so a suite watching its own isolated store also counted
    /// changes made by every other test target in the process. That presents as a
    /// count-off-by-one about one run in ten, which reads like a broken assertion rather
    /// than like a race. The app has one store and observes with nil, so nothing changes
    /// there; anyone who needs to care now can.
    static func post() {
        NotificationCenter.default.post(name: Preferences.didChange, object: Preferences.store)
    }

    static func number(_ key: String, default fallback: CGFloat,
                       in range: ClosedRange<CGFloat>) -> CGFloat {
        guard let raw = Preferences.store.object(forKey: key) as? Double else { return fallback }
        return min(max(CGFloat(raw), range.lowerBound), range.upperBound)
    }

    /// `current` is passed in rather than re-read with a sentinel default. A NaN sentinel
    /// looks natural here and is a trap: every comparison against NaN is false, so the
    /// no-op guard rejected every write and nothing could be set at all.
    static func setNumber(_ key: String, _ value: CGFloat, current: CGFloat,
                          in range: ClosedRange<CGFloat>) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard abs(clamped - current) > 0.0001 else { return }
        Preferences.store.set(Double(clamped), forKey: key)
        post()
    }

    static func flag(_ key: String, default fallback: Bool) -> Bool {
        Preferences.store.object(forKey: key) as? Bool ?? fallback
    }

    static func setFlag(_ key: String, _ value: Bool, current: Bool) {
        guard value != current else { return }
        Preferences.store.set(value, forKey: key)
        post()
    }

    static func string(_ key: String, default fallback: String) -> String {
        let stored = Preferences.store.string(forKey: key) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    static func setString(_ key: String, _ value: String, current: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed != current else { return }
        Preferences.store.set(trimmed, forKey: key)
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
