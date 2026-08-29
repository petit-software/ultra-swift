import AppKit
import Foundation
import SwiftUI

/// Settings that change how the app *looks*, as opposed to how it works.
///
/// The counterpart to `Preferences`, and deliberately a separate namespace: these are the
/// numbers the design language is made of — the glass, the panes' corners and shadows, the
/// window's tint and edge — and every one of them was a constant in `Token` until it needed
/// to be tried against a real desktop rather than argued about.
///
/// The rule the constants already followed still holds: **today's value is the default**.
/// Nothing here changes how the app looks until someone moves a control, and `reset()` puts
/// every one of them back.
///
/// Shares `Preferences.store` and `Preferences.didChange`, so one observer covers both and
/// a look change reaches live views by the same path a font-size change does.
public enum Appearance {

    // MARK: - Choices

    /// Which of the two materials `NSGlassEffectView` offers.
    ///
    /// `.regular` is the standard Liquid Glass; `.clear` is the thinner, more transparent
    /// one. The app has only ever used `.regular` — `style` was never set at all — so this
    /// is the first time the other is reachable without a rebuild.
    public enum GlassStyle: String, CaseIterable, Sendable, Identifiable {
        case regular, clear
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }

        public var style: NSGlassEffectView.Style {
            switch self {
            case .regular: .regular
            case .clear: .clear
            }
        }
    }

    /// Whether the pane's glass is tinted, and toward what.
    ///
    /// `off` leaves `tintColor` nil, which is what the app shipped with. The accent is the
    /// only colour offered on purpose: a second tint that is not the app's one accent is a
    /// second accent, and the whole point of `Preferences.accentColour` is that there is not
    /// one of those.
    public enum GlassTint: String, CaseIterable, Sendable, Identifiable {
        case off, accent
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: "None"
            case .accent: "Accent"
            }
        }
    }

    /// The material behind the whole window, under the panes and their gutters.
    ///
    /// Only the materials that make sense edge-to-edge behind a window are offered.
    /// `.underWindowBackground` is what the app shipped with and is the one designed for
    /// exactly this job; the rest are here to be compared against it.
    public enum WindowMaterial: String, CaseIterable, Sendable, Identifiable {
        case underWindowBackground, windowBackground, sidebar, headerView, hudWindow, popover, menu

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .underWindowBackground: "Under Window"
            case .windowBackground: "Window Background"
            case .sidebar: "Sidebar"
            case .headerView: "Header"
            case .hudWindow: "HUD"
            case .popover: "Popover"
            case .menu: "Menu"
            }
        }

        public var material: NSVisualEffectView.Material {
            switch self {
            case .underWindowBackground: .underWindowBackground
            case .windowBackground: .windowBackground
            case .sidebar: .sidebar
            case .headerView: .headerView
            case .hudWindow: .hudWindow
            case .popover: .popover
            case .menu: .menu
            }
        }
    }

    // MARK: - Glass

    public static var glassStyle: GlassStyle {
        get { choice("glassStyle", default: .regular) }
        set { setChoice("glassStyle", newValue, current: glassStyle) }
    }

    public static var glassTint: GlassTint {
        get { choice("glassTint", default: .off) }
        set { setChoice("glassTint", newValue, current: glassTint) }
    }

    /// How much of the accent a tinted pane carries. Ignored while `glassTint` is `off`.
    public static var glassTintStrength: CGFloat {
        get { PreferenceStore.number(key("glassTintStrength"), default: 0.20, in: 0...0.6) }
        set { PreferenceStore.setNumber(key("glassTintStrength"), newValue,
                                        current: glassTintStrength, in: 0...0.6) }
    }

    /// Put every pane's glass inside one `NSGlassEffectContainerView`.
    ///
    /// OFF, and opt-in rather than opt-out. The container is Apple's documented way to make
    /// many sibling glass views cheap — it batches them into one render pass — and this app
    /// has one glass view per pane, which is exactly the shape it is for. But it also
    /// "elevates the z-order of descendants above the contentView" and MERGES views that
    /// come within `mergeSpacing` of each other, and both of those change how the canvas
    /// composites rather than merely how fast it draws. A default that can rearrange the
    /// panes is not a default; it is something to look at first.
    public static var mergesPaneGlass: Bool {
        get { PreferenceStore.flag(key("mergesPaneGlass"), default: false) }
        set { PreferenceStore.setFlag(key("mergesPaneGlass"), newValue, current: mergesPaneGlass) }
    }

    /// How close two panes' glass has to be before the container fuses them into one
    /// surface. Zero — the system default — batches for speed and merges nothing.
    public static var glassMergeSpacing: CGFloat {
        get { PreferenceStore.number(key("glassMergeSpacing"), default: 0, in: 0...60) }
        set { PreferenceStore.setNumber(key("glassMergeSpacing"), newValue,
                                        current: glassMergeSpacing, in: 0...60) }
    }

    // MARK: - Panes

    /// Pane corner radius. See `Token.Space.paneRadius` for why it is not concentric with
    /// the window's.
    public static var paneRadius: CGFloat {
        get { PreferenceStore.number(key("paneRadius"), default: 18, in: 0...36) }
        set { PreferenceStore.setNumber(key("paneRadius"), newValue, current: paneRadius, in: 0...36) }
    }

    /// How far a pane lifts off the material behind it. Depth, not borders, is what makes a
    /// grid of panes read as separate surfaces.
    public static var paneShadowRadius: CGFloat {
        get { PreferenceStore.number(key("paneShadowRadius"), default: 10, in: 0...36) }
        set { PreferenceStore.setNumber(key("paneShadowRadius"), newValue,
                                        current: paneShadowRadius, in: 0...36) }
    }

    public static var paneShadowOpacity: CGFloat {
        get { PreferenceStore.number(key("paneShadowOpacity"), default: 0.28, in: 0...1) }
        set { PreferenceStore.setNumber(key("paneShadowOpacity"), newValue,
                                        current: paneShadowOpacity, in: 0...1) }
    }

    /// The gutter between panes — how much of the window's material is actually visible.
    ///
    /// The reason the glass reads at all. At 6pt it was there and invisible, which is the
    /// worst of both, and that is why the shipped value is twice that.
    public static var paneGutter: CGFloat {
        get { PreferenceStore.number(key("paneGutter"), default: 12, in: 0...40) }
        set { PreferenceStore.setNumber(key("paneGutter"), newValue, current: paneGutter, in: 0...40) }
    }

    /// How far the panes sit from the WINDOW's edges — the frame of material around the
    /// whole canvas, as opposed to `paneGutter`, which is the space between panes.
    ///
    /// One knob where the layout has two. `LayoutMetrics` splits the same three edges into
    /// `padding` and `edgeInset` and adds them together in `contentRect`, so a user-facing
    /// pair would be two sliders that do the identical thing. The app puts the whole inset
    /// in `padding` and zeroes `edgeInset`.
    ///
    /// 8pt, which is 4 tighter than the 8 + 4 the two internal fields shipped with. The
    /// window's own frame of material was reading as wider than the gutters between the
    /// panes, so the outer edge drew more attention than the divisions that carry meaning.
    ///
    /// The LEADING, TRAILING and BOTTOM edges only. The top is the toolbar's: its content
    /// layout rect already holds the panes off the window's top edge, and adding to it there
    /// reads as a second gap under the toolbar rather than as breathing room.
    public static var windowPadding: CGFloat {
        get { PreferenceStore.number(key("windowPadding"), default: 8, in: 0...48) }
        set { PreferenceStore.setNumber(key("windowPadding"), newValue,
                                        current: windowPadding, in: 0...48) }
    }

    public static var focusRingWidth: CGFloat {
        get { PreferenceStore.number(key("focusRingWidth"), default: 2, in: 0...6) }
        set { PreferenceStore.setNumber(key("focusRingWidth"), newValue,
                                        current: focusRingWidth, in: 0...6) }
    }

    /// How much of the accent the focused pane's ring carries. Translucent on purpose — see
    /// `Token.Colour.accentMuted` for why an opaque mix reads wrong.
    public static var focusRingStrength: CGFloat {
        get { PreferenceStore.number(key("focusRingStrength"), default: 0.25, in: 0.05...1) }
        set { PreferenceStore.setNumber(key("focusRingStrength"), newValue,
                                        current: focusRingStrength, in: 0.05...1) }
    }

    // MARK: - Window

    /// `.hudWindow` rather than `.underWindowBackground`, which the app shipped with.
    ///
    /// The HUD material is darker and less transparent, and that is what a window full of
    /// terminals wants: `.underWindowBackground` is tuned for a document window sitting over
    /// a desktop, so whatever happened to be behind Ultra came through the gutters and read
    /// as noise between the panes rather than as one surface. The rest of the list is still
    /// there to be compared against it.
    public static var windowMaterial: WindowMaterial {
        get { choice("windowMaterial", default: .hudWindow) }
        set { setChoice("windowMaterial", newValue, current: windowMaterial) }
    }

    /// How much black is laid over the material in dark appearance, so the glass reads as
    /// smoked rather than as clear frost.
    public static var windowTintDark: CGFloat {
        get { PreferenceStore.number(key("windowTintDark"), default: 0.30, in: 0...1) }
        set { PreferenceStore.setNumber(key("windowTintDark"), newValue,
                                        current: windowTintDark, in: 0...1) }
    }

    /// The same in light appearance, where the tint LIFTS instead of darkening. White needs
    /// more of itself to read as a surface than black needs to read as smoke, which is why
    /// the two defaults are not the same number.
    public static var windowTintLight: CGFloat {
        get { PreferenceStore.number(key("windowTintLight"), default: 0.45, in: 0...1) }
        set { PreferenceStore.setNumber(key("windowTintLight"), newValue,
                                        current: windowTintLight, in: 0...1) }
    }

    /// The window's visible corner radius.
    ///
    /// The floor is not a taste decision: AppKit masks a titled window to 15.5pt, so a
    /// LARGER radius draws strictly inside that mask and only our arc is ever seen. Going
    /// below it pokes outside the mask and produces two concentric arcs at every corner.
    /// The range starts where the system's mask does, so the control cannot reach the bug.
    public static var windowRadius: CGFloat {
        get {
            PreferenceStore.number(key("windowRadius"), default: 24,
                                   in: Token.Space.systemWindowRadius...44)
        }
        set {
            PreferenceStore.setNumber(key("windowRadius"), newValue, current: windowRadius,
                                      in: Token.Space.systemWindowRadius...44)
        }
    }

    /// The window's edge. Thicker than a hairline so the window still has a boundary once
    /// its surface is glass over an arbitrary desktop.
    public static var windowBorderWidth: CGFloat {
        get { PreferenceStore.number(key("windowBorderWidth"), default: 1.5, in: 0...4) }
        set { PreferenceStore.setNumber(key("windowBorderWidth"), newValue,
                                        current: windowBorderWidth, in: 0...4) }
    }

    /// How strongly that edge reads. Light in dark appearance, dark in light — one number
    /// for both, because it is one idea.
    public static var windowBorderStrength: CGFloat {
        get { PreferenceStore.number(key("windowBorderStrength"), default: 0.22, in: 0...1) }
        set { PreferenceStore.setNumber(key("windowBorderStrength"), newValue,
                                        current: windowBorderStrength, in: 0...1) }
    }

    // MARK: - Pane headers

    /// Gaussian radius behind a pane's title, so text passing under the header genuinely
    /// dissolves rather than looking merely soft.
    public static var headerBlurRadius: CGFloat {
        get { PreferenceStore.number(key("headerBlurRadius"), default: 14, in: 0...40) }
        set { PreferenceStore.setNumber(key("headerBlurRadius"), newValue,
                                        current: headerBlurRadius, in: 0...40) }
    }

    /// How much the header darkens — or, in light appearance, lightens — at its solid edge.
    /// Blur separates a title from a busy backdrop; over a near-uniform one this is what
    /// does the work.
    public static var headerTintOpacity: CGFloat {
        get { PreferenceStore.number(key("headerTintOpacity"), default: 0.28, in: 0...1) }
        set { PreferenceStore.setNumber(key("headerTintOpacity"), newValue,
                                        current: headerTintOpacity, in: 0...1) }
    }

    // MARK: - Storage

    private static let prefix = "appearance."
    private static func key(_ name: String) -> String { prefix + name }

    /// Every key this namespace owns. `reset()` reads it, and so does the test that stops a
    /// new setting being added without one — a knob that `reset()` cannot reach is a knob
    /// that "Reset to Defaults" quietly lies about.
    public static let keys = [
        "glassStyle", "glassTint", "glassTintStrength", "mergesPaneGlass", "glassMergeSpacing",
        "paneRadius", "paneShadowRadius", "paneShadowOpacity", "paneGutter",
        "focusRingWidth", "focusRingStrength",
        "windowMaterial", "windowTintDark", "windowTintLight", "windowRadius", "windowPadding",
        "windowBorderWidth", "windowBorderStrength",
        "headerBlurRadius", "headerTintOpacity",
    ]

    public static func reset() {
        clear()
        PreferenceStore.post()
    }

    /// Remove the keys WITHOUT announcing it. `Preferences.reset()` clears both namespaces
    /// and then posts once — a reset that fires two notifications makes every observer do
    /// its work twice and breaks any test counting them.
    static func clear() {
        for name in keys { Preferences.store.removeObject(forKey: key(name)) }
    }

    private static func choice<T: RawRepresentable>(_ name: String, default fallback: T) -> T
    where T.RawValue == String {
        Preferences.store.string(forKey: key(name)).flatMap(T.init(rawValue:)) ?? fallback
    }

    private static func setChoice<T: RawRepresentable & Equatable>(_ name: String, _ value: T,
                                                                   current: T)
    where T.RawValue == String {
        guard value != current else { return }
        Preferences.store.set(value.rawValue, forKey: key(name))
        PreferenceStore.post()
    }
}
