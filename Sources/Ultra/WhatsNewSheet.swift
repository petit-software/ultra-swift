import AppKit
import SwiftUI
import UltraCore
import UltraDesign

/// What a release changed, in a few lines, shown once on the first launch after an update.
///
/// The list comes from the release itself — the `whats-new.md` that `scripts/release.sh`
/// publishes beside every DMG, made from the bold leads of the release's description — so
/// the app ships no copy of its own changelog and the dialog can never describe a release
/// other than the one running. See `WhatsNew` for the pure half of this.
///
/// The automatic showing is a setting (`Preferences.showsWhatsNew`, on by default), and
/// Ultra ▸ What's New in Ultra… shows the current version's list at any time — which is
/// also how it is seen on a copy built from source, where an automatic dialog on every
/// version bump would be noise.
@MainActor
final class WhatsNewChecker {
    static let shared = WhatsNewChecker()

    private var checkedThisLaunch = false

    private init() {}

    /// This copy's version, as the release was tagged.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var feed: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// The first window of a launch asks. Once per launch, and only on a copy that updates:
    /// a checkout's version moves with every bump and none of them is an update.
    ///
    /// Fetched before anything is shown, so an offline launch shows nothing and does NOT
    /// record the version — the next launch tries again. The version is recorded on a
    /// fresh install as well, so that the first update after it is seen.
    func checkAfterUpdate(present: @escaping @MainActor (WhatsNewContent) -> Void) async {
        guard !checkedThisLaunch else { return }
        checkedThisLaunch = true
        let current = Self.currentVersion
        let seen = Preferences.whatsNewSeenVersion
        if seen.isEmpty {
            Preferences.whatsNewSeenVersion = current
            return
        }
        guard !Updater.isBuiltFromSource,
              WhatsNew.isDue(current: current, seen: seen, enabled: Preferences.showsWhatsNew)
        else { return }
        guard let items = await fetch(version: current), !items.isEmpty else { return }
        Preferences.whatsNewSeenVersion = current
        present(WhatsNewContent(version: current, items: items))
    }

    /// The menu's path: the running version's list, whatever has been seen. An empty list
    /// is shown as such, with the release page a click away — a dialog that silently did
    /// not open would look like a broken menu item.
    func show(present: @escaping @MainActor (WhatsNewContent) -> Void) async {
        let current = Self.currentVersion
        let items = await fetch(version: current) ?? []
        present(WhatsNewContent(version: current, items: items))
    }

    /// The release's list, or nil when it cannot be had: offline, or a release cut before
    /// the asset existed.
    func fetch(version: String) async -> [String]? {
        guard let url = WhatsNew.assetURL(version: version, feed: Self.feed) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return WhatsNew.items(in: text)
    }

    static func pageURL(version: String) -> URL? {
        WhatsNew.pageURL(version: version, feed: feed)
    }
}

/// One release's list, as the sheet shows it.
struct WhatsNewContent: Identifiable, Equatable {
    let version: String
    let items: [String]
    var id: String { version }
}

/// The dialog. Laid out like the Customize sheet — a title, the content, Done — so the
/// app's few sheets read as one family.
struct WhatsNewSheet: View {
    let content: WhatsNewContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's New in Ultra \(content.version)")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)

            if content.items.isEmpty {
                Text("This release's list could not be fetched. The release notes have the whole story.")
                    .foregroundStyle(Token.Colour.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(content.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.caption)
                                .foregroundStyle(Token.Colour.accent)
                            Text(item)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                // Plain, in the accent, like the Customize sheet's secondary action.
                Button("Release Notes") {
                    if let url = WhatsNewChecker.pageURL(version: content.version) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Token.Colour.accent)
                .controlSize(.large)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done").foregroundStyle(Token.Colour.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Token.Colour.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Escape closes it, like every sheet here; Return is Done.
        .onExitCommand { dismiss() }
    }
}

#Preview("What's new", traits: .fixedLayout(width: 480, height: 300)) {
    WhatsNewSheet(content: WhatsNewContent(version: "0.32.0", items: [
        "A window that closes keeps its sessions, and gives them back",
        "⌘W on a project's last pane closes the project",
        "Close Session, in the palette",
    ]))
}

#Preview("What's new — nothing fetched", traits: .fixedLayout(width: 480, height: 200)) {
    WhatsNewSheet(content: WhatsNewContent(version: "0.32.0", items: []))
}
