import CoreGraphics
import Foundation
import Testing
@testable import UltraCanvas
@testable import UltraDesign
@testable import UltraLayout

/// The one place the pure geometry module and the look settings are joined. If these drift,
/// a window opens with different insets from the ones Settings is showing.
@Suite("Canvas metrics follow the look settings")
@MainActor
struct CanvasMetricsTests {

    /// An isolated domain per call, the idiom `AppearanceTests` uses and for the reason
    /// documented on `Preferences.boundStore`: these settings are a global, the suites run in
    /// parallel, and clearing the real store from one test makes another fail about one run
    /// in three. A bound store reaches only this task.
    private func withDefaults(_ body: () -> Void) {
        let name = "ultra.tests.canvasMetrics.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite, body)
    }

    /// The whole window inset lives in one field now. `LayoutMetrics` still declares two —
    /// `padding` and `edgeInset` — and `contentRect` adds them, so the invariant that
    /// matters is that the app's value ends up entirely in the sum.
    @Test("the default puts the whole inset in one field")
    func defaultInsetIsWhollyPadding() {
        withDefaults {
            let settings = LayoutMetrics.fromSettings
            #expect(settings.padding == 8)
            #expect(settings.edgeInset == 0)
            #expect(settings.padding + settings.edgeInset == 8)
        }
    }

    /// Deliberately tighter than the 8 + 4 the two internal fields shipped with: the frame
    /// of material around the canvas was reading as wider than the gutters between the panes.
    @Test("the default insets the canvas by 8pt")
    func defaultContentRect() {
        withDefaults {
            let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
            let content = LayoutMetrics.fromSettings.contentRect(in: bounds)
            let expectedWidth: CGFloat = 1000 - 2 * 8
            #expect(content.minX == 8)
            #expect(content.width == expectedWidth)
            // The top is the toolbar's, at every value of the setting.
            #expect(content.minY == 0)
        }
    }

    @Test("the setting moves the canvas away from the window edge")
    func paddingReachesTheLayout() {
        withDefaults {
            Appearance.windowPadding = 24
            let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
            let content = LayoutMetrics.fromSettings.contentRect(in: bounds)
            // Typed, not written inline as `1000 - 48`: `#expect` decomposes a compound
            // operand and evaluates it on its own, where the literals default to `Int` —
            // so the comparison ran as `CGFloat(952.0) == Int(952)` and was false.
            let expectedWidth: CGFloat = 1000 - 2 * 24
            #expect(content.minX == 24)
            #expect(content.width == expectedWidth)
        }
    }

    /// Zero has to mean zero — a slider whose bottom end still leaves a gap is a slider that
    /// does not do what it says.
    @Test("zero padding runs the panes to the window edge")
    func zeroIsZero() {
        withDefaults {
            Appearance.windowPadding = 0
            let content = LayoutMetrics.fromSettings
                .contentRect(in: CGRect(x: 0, y: 0, width: 1000, height: 700))
            #expect(content.minX == 0)
            #expect(content.width == 1000)
        }
    }

    /// The top edge is the toolbar's. Padding there reads as a second gap under it.
    @Test("padding never touches the top edge")
    func topIsLeftAlone() {
        withDefaults {
            Appearance.windowPadding = 40
            #expect(LayoutMetrics.fromSettings.topPadding == 0)
        }
    }

    @Test("the gutter setting rides along too")
    func gutterFollows() {
        withDefaults {
            Appearance.paneGutter = 20
            #expect(LayoutMetrics.fromSettings.gutter == 20)
        }
    }

    /// `PreferenceBridge` fires on every preference write and guards on this. If it answered
    /// false for metrics that already match, every write would re-lay out every canvas.
    @Test("metrics already in step report so")
    func matchesSettingsIsHonest() {
        withDefaults {
            Appearance.windowPadding = 18
            Appearance.paneGutter = 6
            #expect(LayoutMetrics.fromSettings.matchesSettings)

            var stale = LayoutMetrics.fromSettings
            stale.padding = 3
            #expect(!stale.matchesSettings)
            stale.applySettings()
            #expect(stale.matchesSettings)
        }
    }

    /// `applySettings` owns three fields and must not quietly reset the rest — the backing
    /// scale in particular is set per window from `backingScaleFactor`, and losing it makes
    /// every frame snap to the wrong pixel grid.
    @Test("applying settings leaves the non-setting fields alone")
    func othersUntouched() {
        withDefaults {
            var metrics = LayoutMetrics.default
            metrics.scale = 3
            metrics.minPaneSize = CGSize(width: 200, height: 100)
            metrics.dividerHitWidth = 22
            metrics.applySettings()
            #expect(metrics.scale == 3)
            #expect(metrics.minPaneSize == CGSize(width: 200, height: 100))
            #expect(metrics.dividerHitWidth == 22)
        }
    }
}
