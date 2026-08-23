import AppKit
import Foundation
import Sparkle

/// Updates, from GitHub Releases, via Sparkle.
///
/// The one rule worth stating first: **a build from source never offers an update.** Ultra is
/// developed by running `scripts/build-app.sh` in a checkout, and an updater that offers to
/// replace a developer's own build with a release would overwrite uncommitted work with a
/// download. It is also the failure nobody notices until it happens to them once.
///
/// A release bundle is stamped with `SUFeedURL` by `scripts/release.sh`; a local build is not,
/// and is additionally recognised by sitting next to a `Package.swift`. Either check alone
/// would do — both are here because the cost is one `FileManager` call and the cost of being
/// wrong is someone's working tree.
@MainActor
final class Updater {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    private init() {}

    /// Whether this copy is one that may be updated at all.
    static var isUpdatable: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty else { return false }
        return !isBuiltFromSource
    }

    /// Is this bundle sitting inside a source checkout?
    ///
    /// `build-app.sh` writes `Ultra.app` into the repository root, so the marker is a
    /// `Package.swift` beside it. A copy dragged to /Applications has no such neighbour.
    static var isBuiltFromSource: Bool {
        let bundle = Bundle.main.bundleURL.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath:
            bundle.appendingPathComponent("Package.swift").path)
    }

    /// Start Sparkle, if this copy is allowed to update.
    ///
    /// Not created at all otherwise: an updater with no feed logs an error on every check and
    /// puts a menu item on screen that cannot work.
    func startIfUpdatable() {
        guard Self.isUpdatable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    var canCheck: Bool { controller != nil }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Whether Sparkle checks on its own. Surfaced in Settings rather than left to Sparkle's
    /// first-run prompt, so the answer lives with every other preference.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// What Settings says when there is nothing to offer — naming the reason, because
    /// "Check for Updates" simply being absent is the kind of thing people file bugs about.
    static var unavailableReason: String? {
        if isBuiltFromSource {
            return "This copy was built from source, so it updates by rebuilding it."
        }
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil {
            return "This copy has no update feed, so it cannot check for updates."
        }
        return nil
    }
}
