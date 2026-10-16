import Foundation

/// The short list a release ships, and when a launch should show it.
///
/// A release's description on GitHub is prose — a paragraph per change, each opening with
/// a bold lead. `scripts/release.sh` takes those leads and publishes them beside the DMG
/// as `whats-new.md`, one line each, which is the whole of what the app reads: the app
/// never parses the prose, so the two cannot disagree about what the headlines were, and
/// a release with no leads is refused before it is cut rather than shown as an empty
/// dialog. Pure, so it is tested; the fetching is the app's.
public enum WhatsNew {
    /// The asset's name, beside the DMG on the release.
    public static let assetName = "whats-new.md"

    /// The repository's releases, for a copy with no feed to derive them from.
    public static let defaultReleases = "https://github.com/petit-software/ultra-swift/releases"

    /// The lines of the list, as the app shows them: the list's own bullets taken off,
    /// blank lines and headings dropped. A line that is nothing but a marker is dropped
    /// too — the release script never writes one, but a hand-edited asset might.
    public static func items(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var item = Substring(line).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, !item.hasPrefix("#") else { return nil }
            for marker in ["-", "*", "•"] where item == marker || item.hasPrefix(marker + " ") {
                item = String(item.dropFirst()).trimmingCharacters(in: .whitespaces)
                break
            }
            return item.isEmpty ? nil : item
        }
    }

    /// Where the releases live, from the update feed when there is one.
    ///
    /// The feed is `…/releases/latest/download/appcast.xml`; the releases are everything
    /// before `/latest/`. A copy built from source has no feed and uses the repository's.
    public static func releases(feed: String?) -> String {
        guard let feed, let range = feed.range(of: "/releases/") else { return defaultReleases }
        return String(feed[..<range.upperBound].dropLast())
    }

    /// The list for one version: the `whats-new.md` asset of the release tagged `v<version>`.
    public static func assetURL(version: String, feed: String?) -> URL? {
        URL(string: "\(releases(feed: feed))/download/v\(version)/\(assetName)")
    }

    /// The release's own page, for "the whole story".
    public static func pageURL(version: String, feed: String?) -> URL? {
        URL(string: "\(releases(feed: feed))/tag/v\(version)")
    }
}
