import AppKit
import Foundation
import UltraDesign

/// The wait between a polling tile's refreshes.
///
/// Every polling tile shells out to a real command — `lsof`, `ps`, `git` — so the interval
/// is the difference between a live readout and a laptop that never idles. Worse, a tile
/// behind a hidden window is spending that budget to update pixels nobody can see, which is
/// why the wait extends for as long as the app is fully occluded.
public enum TilePolling {

    /// Wait one interval, then keep waiting while every window is occluded.
    ///
    /// Deliberately checks occlusion AFTER the interval rather than before: a tile that has
    /// just become visible should refresh promptly rather than sit out the remainder of a
    /// wait it started while hidden.
    public static func tick(_ seconds: CGFloat) async {
        try? await Task.sleep(for: .seconds(Double(seconds)))
        guard Preferences.pausePollingWhenOccluded else { return }
        while !Task.isCancelled, await !isVisible() {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// True when any window is on screen and not fully covered. `occlusionState` is the
    /// system's own answer to "can the user actually see this", and it accounts for other
    /// apps' windows on top, not just minimisation.
    @MainActor
    public static func isVisible() -> Bool {
        let windows = NSApp?.windows ?? []
        guard !windows.isEmpty else { return true }   // nothing to judge: keep polling
        return windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }
}
