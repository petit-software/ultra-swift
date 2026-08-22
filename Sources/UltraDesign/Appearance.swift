import Foundation
import SwiftUI

/// User-adjustable appearance values, stored in `UserDefaults`.
///
/// Every value here used to be a `static let` on `Token`. Those constants are now the
/// *defaults* and the tokens read through this, so no call site changed — which is the whole
/// reason this is cheap. The alternative was shipping a guess at each number and asking
/// whether it looked right; a slider finds it in a second.
public enum Appearance {

    public enum Key: String, CaseIterable, Sendable {
        case windowRadius
        case windowBorderWidth
        case windowTintOpacity
        case paneRadius
        case paneShadowRadius
        case paneShadowOpacity
        case gutter
        case canvasPadding
        case headerBlurRadius
        case headerTintOpacity
    }

    /// Today's shipped constants. A missing default is a programming error, not a 0.
    public static let fallbacks: [Key: CGFloat] = [
        .windowRadius: 24,
        .windowBorderWidth: 1.5,
        .windowTintOpacity: 0.30,
        .paneRadius: 18,
        .paneShadowRadius: 10,
        .paneShadowOpacity: 0.28,
        .gutter: 12,
        .canvasPadding: 12,
        .headerBlurRadius: 14,
        .headerTintOpacity: 0.28,
    ]

    /// Posted after any change, including a reset. AppKit views listen and re-apply; SwiftUI
    /// reads through `AppearanceModel`.
    public static let didChange = Notification.Name("com.ultra.appearance.didChange")

    private static let prefix = "appearance."

    /// Where the values live. Injectable so tests can use an isolated suite; two test
    /// suites mutating the same keys in `.standard` is a genuine flake.
    public nonisolated(unsafe) static var store: UserDefaults = .standard

    public static func value(_ key: Key) -> CGFloat {
        let fallback = fallbacks[key] ?? 0
        guard let stored = store.object(forKey: prefix + key.rawValue) as? Double
        else { return fallback }
        return clamp(CGFloat(stored), to: key)
    }

    public static func set(_ key: Key, _ newValue: CGFloat) {
        let clamped = clamp(newValue, to: key)
        guard abs(clamped - value(key)) > 0.0001 else { return }
        store.set(Double(clamped), forKey: prefix + key.rawValue)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func reset() {
        for key in Key.allCases {
            store.removeObject(forKey: prefix + key.rawValue)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var isModified: Bool {
        Key.allCases.contains { abs(value($0) - (fallbacks[$0] ?? 0)) > 0.0001 }
    }

    /// Clamping happens on the way IN and on the way OUT.
    ///
    /// Out matters as much as in: a value written by an older build, a synced defaults
    /// domain, or `defaults write` from a shell has never passed through the slider. The
    /// `windowRadius` floor is not cosmetic — below `systemWindowRadius` the window's corner
    /// pokes outside AppKit's mask and the doubled-arc glitch comes back.
    static func clamp(_ raw: CGFloat, to key: Key) -> CGFloat {
        let range = knob(key).range
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    // MARK: - Knobs

    /// One row of the Appearance tab. Data, so the UI is a `ForEach` rather than ten
    /// hand-written sliders that drift out of step with the values behind them.
    public struct Knob: Identifiable, Sendable {
        public var id: Key { key }
        public let key: Key
        public let title: String
        public let range: ClosedRange<CGFloat>
        public let step: CGFloat
        /// Values that read as a percentage are shown as one; points are shown as points.
        public let isPercentage: Bool
        public let footnote: String?

        public func format(_ value: CGFloat) -> String {
            isPercentage ? "\(Int((value * 100).rounded()))%"
                         : (value == value.rounded() ? "\(Int(value)) pt"
                                                     : String(format: "%.1f pt", value))
        }
    }

    public static func knob(_ key: Key) -> Knob {
        switch key {
        case .windowRadius:
            Knob(key: key, title: "Window corner", range: Token.Space.systemWindowRadius...40,
                 step: 0.5, isPercentage: false,
                 footnote: "Cannot go below 15.5 pt. AppKit masks the window at that radius, "
                         + "and a smaller corner pokes outside the mask — which is what draws "
                         + "two arcs at every corner.")
        case .windowBorderWidth:
            Knob(key: key, title: "Window edge", range: 0...4, step: 0.5, isPercentage: false,
                 footnote: nil)
        case .windowTintOpacity:
            Knob(key: key, title: "Window tint", range: 0...0.8, step: 0.01, isPercentage: true,
                 footnote: "How much the glass is smoked. At 0 the window is clear frost.")
        case .paneRadius:
            Knob(key: key, title: "Pane corner", range: 0...32, step: 1, isPercentage: false,
                 footnote: nil)
        case .paneShadowRadius:
            Knob(key: key, title: "Pane shadow size", range: 0...30, step: 1,
                 isPercentage: false, footnote: nil)
        case .paneShadowOpacity:
            Knob(key: key, title: "Pane shadow strength", range: 0...1, step: 0.01,
                 isPercentage: true,
                 footnote: "Depth is what separates panes. At 0 they read as flat rectangles.")
        case .gutter:
            Knob(key: key, title: "Gap between panes", range: 0...32, step: 1,
                 isPercentage: false,
                 footnote: "The material is only visible in these gaps.")
        case .canvasPadding:
            Knob(key: key, title: "Window padding", range: 0...32, step: 1,
                 isPercentage: false, footnote: nil)
        case .headerBlurRadius:
            Knob(key: key, title: "Header blur", range: 0...40, step: 1, isPercentage: false,
                 footnote: "Blur separates a pane's title from a busy backdrop.")
        case .headerTintOpacity:
            Knob(key: key, title: "Header tint", range: 0...0.8, step: 0.01,
                 isPercentage: true,
                 footnote: "Over a near-uniform backdrop, blur does almost nothing and this "
                         + "is what keeps the title legible. It is also the part that "
                         + "survives Reduce Transparency, where the blur is dropped.")
        }
    }

    public static var allKnobs: [Knob] { Key.allCases.map(knob) }
}

/// SwiftUI's view of the settings. Bindings write through `Appearance`, so a slider drag
/// updates the live window as it moves rather than on commit.
@MainActor
@Observable
public final class AppearanceModel {
    public static let shared = AppearanceModel()

    /// Bumped on every change so SwiftUI re-reads. The values themselves live in defaults.
    public private(set) var revision = 0

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: Appearance.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision &+= 1 }
            }
    }

    public func binding(_ key: Appearance.Key) -> Binding<CGFloat> {
        Binding(get: { _ = self.revision; return Appearance.value(key) },
                set: { Appearance.set(key, $0) })
    }

    public func reset() { Appearance.reset() }
}
