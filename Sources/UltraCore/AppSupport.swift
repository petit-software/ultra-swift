import Foundation

/// Ultra's folder in Application Support: `Ultra`, or `Ultra Dev` for the copy
/// `scripts/build-app.sh --dev` makes.
///
/// The dev build runs BESIDE the Ultra in use, and its own bundle id already keeps its
/// defaults apart — but this folder is not keyed by bundle id, so without the split the two
/// would load and rewrite the same saved workspaces: a build being tried could overwrite the
/// layout of the app the user is working in.
public enum AppSupport {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName(forBundleID: Bundle.main.bundleIdentifier),
                                    isDirectory: true)
    }

    /// By bundle id rather than by name: the id is what `build-app.sh --dev` sets to tell
    /// the copies apart, and a name is something a user can change in Finder.
    static func folderName(forBundleID bundleID: String?) -> String {
        bundleID?.hasSuffix(".dev") == true ? "Ultra Dev" : "Ultra"
    }
}
