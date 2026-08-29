import UltraDesign
import UltraLayout

public extension LayoutMetrics {
    /// The metrics the look settings currently ask for.
    ///
    /// `UltraLayout` knows nothing about preferences — it is a pure geometry module with no
    /// dependencies, which is what lets the layout tests run without a defaults store. This
    /// is the one place the two are joined, so a canvas built at launch and a canvas updated
    /// by `PreferenceBridge` cannot end up reading the settings differently.
    ///
    /// Before it existed, `LayoutStore` took `LayoutMetrics.default` — the hard-coded 12pt
    /// gutter — and a window opened with a customised gutter showed the stock one until the
    /// next preference write happened to push the real value in.
    static var fromSettings: LayoutMetrics {
        var metrics = LayoutMetrics.default
        metrics.applySettings()
        return metrics
    }

    /// Bring the settings-owned fields of an existing value up to date, leaving everything
    /// else — `scale`, `minPaneSize`, the divider widths — exactly as it was.
    mutating func applySettings() {
        gutter = Appearance.paneGutter
        // The whole window inset goes in `padding`, and `edgeInset` is zeroed. The layout
        // adds the two together for the same three edges, so one user-facing knob has to
        // pick one of them to live in; splitting a slider across both would be two controls
        // for one distance. `topPadding` stays at zero — see `Appearance.windowPadding`.
        padding = Appearance.windowPadding
        edgeInset = 0
    }

    /// Are the settings-owned fields already what the settings ask for? `PreferenceBridge`
    /// fires on EVERY preference write, and re-laying out a canvas for a setting that did
    /// not change is a visible hitch in a window with a lot of panes.
    var matchesSettings: Bool {
        gutter == Appearance.paneGutter && padding == Appearance.windowPadding && edgeInset == 0
    }
}
