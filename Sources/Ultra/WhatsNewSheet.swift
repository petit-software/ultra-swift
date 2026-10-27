import AppKit
import SwiftUI
import UltraCore
import UltraDesign

/// What a release changed, in a few lines, on request from Ultra ▸ What's New in Ultra….
///
/// The list comes from the release itself — the `whats-new.md` that `scripts/release.sh`
/// publishes beside every DMG, made from the bold leads of the release's description — so
/// the app ships no copy of its own changelog and the dialog can never describe a release
/// other than the one running. See `WhatsNew` for the pure half of this.
///
/// On request ONLY. It used to open on its own on the first launch after an update, and
/// that was the same list twice: Sparkle's update prompt shows the release notes, made from
/// the same file, before the update is installed. The menu item is the one place it lives
/// now — which is also how it is seen on a copy built from source.
@MainActor
final class WhatsNewChecker {
    static let shared = WhatsNewChecker()

    private init() {}

    /// This copy's version, as the release was tagged.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var feed: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// The menu's path: the running version's list. An empty list is shown as such, with
    /// the release page a click away — a dialog that silently did not open would look
    /// like a broken menu item.
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

/// The dialog: the app's icon on the left, and on the right the title and the release's
/// list, with Release Notes and Done under them. The icon is the way an About box and an
/// installer say "this app" — a sheet of text alone read as a message from nowhere.
/// The buttons are the Customize sheet's, so the app's few sheets read as one family.
struct WhatsNewSheet: View {
    let content: WhatsNewContent
    @Environment(\.dismiss) private var dismiss

    /// The running copy's own icon — Ultra's, or Ultra Dev's on a dev build — rather than
    /// an asset of this view's, so the two cannot drift.
    private var icon: NSImage {
        NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What's New in Ultra")
                            .font(.title2.weight(.semibold))
                        Text("Version \(content.version)")
                            .font(.callout)
                            .foregroundStyle(Token.Colour.secondaryLabel)
                    }
                    .padding(.top, 4)

                    if content.items.isEmpty {
                        Text("This release's list could not be fetched. The release notes have the whole story.")
                            .foregroundStyle(Token.Colour.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // A dash, as the release's own list is written: a sparkle in
                        // front of every line made each one read as a feature flagged
                        // special, when the list is the plain record of what changed.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(content.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("–")
                                        .foregroundStyle(Token.Colour.secondaryLabel)
                                    Text(item)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A hairline parts the list from the buttons, as the Customize sheet's footer
            // is parted from its form: the buttons are the sheet's, not the list's.
            Rectangle()
                .fill(Token.Colour.separator)
                .frame(height: 1)
                .padding(.horizontal, -20)

            // No focus ring on either: the sheet opens with the keyboard on its first
            // button, and a ring round Release Notes read as "press Return for the web
            // page" when Return is Done. Both stay reachable by Tab with Full Keyboard
            // Access; only the ring is gone, and Return and Esc are the keys that matter.
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
                .focusEffectDisabled()
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
                .focusEffectDisabled()
            }
        }
        .padding(20)
        .frame(width: 520)
        // Escape closes it, like every sheet here; Return is Done.
        .onExitCommand { dismiss() }
    }
}

#Preview("What's new", traits: .fixedLayout(width: 560, height: 320)) {
    WhatsNewSheet(content: WhatsNewContent(version: "0.40.0", items: [
        "A click selects a Context row, Space shows it in Quick Look, a double click sends it",
        "@ and / at an agent's prompt open a picker at the caret",
        "The palette opens, makes and moves between projects",
        "The waiting notification names the project and the agent",
    ]))
}

#Preview("What's new — nothing fetched", traits: .fixedLayout(width: 560, height: 220)) {
    WhatsNewSheet(content: WhatsNewContent(version: "0.32.0", items: []))
}
