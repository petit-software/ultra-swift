import AppKit
import SwiftUI
import UltraCore
import UltraDesign
import UltraLayout

/// M1 pane content: a static terminal transcript.
///
/// The split engine ships and is proven with these before a single PTY exists — debugging
/// layout math through a live shell is miserable. They render as terminals rather than as
/// coloured rectangles because how the engine *feels* is most of what M1 is for, and a
/// grid of flat blocks tells you nothing about that. See docs/04-ROADMAP.md.
public struct TerminalPlaceholderView: View {
    let theme: TerminalTheme
    let transcript: Transcript

    public var body: some View {
        ZStack(alignment: .topLeading) {
            theme.background.opacity(theme.backgroundOpacity)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(transcript.lines.enumerated()), id: \.offset) { _, line in
                    line.view(theme: theme)
                }
                CursorLine(theme: theme)
            }
            .font(Token.Type_.terminal(12.5))
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal, \(transcript.title)")
    }
}

private struct CursorLine: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 0) {
            Text("❯ ").foregroundStyle(theme.green)
            Rectangle()
                .fill(theme.cursor)
                .frame(width: 7.5, height: 16)
        }
    }
}

// MARK: - Transcript fixtures

public struct Transcript: Sendable {
    public enum Line: Sendable {
        case prompt(String)
        case output(String)
        case success(String)
        case warning(String)
        case dim(String)
        case blank

        @ViewBuilder
        func view(theme: TerminalTheme) -> some View {
            switch self {
            case .prompt(let text):
                HStack(spacing: 0) {
                    Text("❯ ").foregroundStyle(theme.green)
                    Text(text).foregroundStyle(theme.foreground)
                }
            case .output(let text): Text(text).foregroundStyle(theme.foreground)
            case .success(let text): Text(text).foregroundStyle(theme.green)
            case .warning(let text): Text(text).foregroundStyle(theme.yellow)
            case .dim(let text): Text(text).foregroundStyle(theme.dimForeground)
            case .blank: Text(" ")
            }
        }
    }

    public var title: String
    public var subtitle: String
    public var icon: String
    public var lines: [Line]

    /// Deterministic, so previews and screenshots are stable run to run.
    public static func fixture(_ index: Int) -> Transcript {
        switch (index - 1) % 5 {
        case 0:
            Transcript(title: "Ultra", subtitle: "~/Repo/Ultra", icon: "apple.terminal",
                       lines: [.prompt("swift build"),
                               .dim("Building for debugging..."),
                               .success("Build complete! (2.62s)"),
                               .blank,
                               .prompt("swift test"),
                               .success("✔ 46 tests in 8 suites passed")])
        case 1:
            Transcript(title: "claude", subtitle: "agent · Ultra", icon: "sparkles",
                       lines: [.dim("● Reading Sources/UltraLayout/Layout.swift"),
                               .dim("● Editing Operations.swift"),
                               .output("Split now takes space only from"),
                               .output("the source pane."),
                               .blank,
                               .success("✔ Done (3 files changed)")])
        case 2:
            Transcript(title: "git", subtitle: "main ▲2", icon: "arrow.trianglehead.branch",
                       lines: [.prompt("git status -sb"),
                               .dim("## main...origin/main [ahead 2]"),
                               .success(" M Sources/UltraLayout/Layout.swift"),
                               .success(" M docs/01-SPLIT-ENGINE.md"),
                               .warning("?? Sources/UltraCanvas/PaneChrome.swift")])
        case 3:
            Transcript(title: "dev", subtitle: ":3000", icon: "server.rack",
                       lines: [.prompt("npm run dev"),
                               .blank,
                               .success("  ready in 412 ms"),
                               .blank,
                               .output("  ➜  Local:   http://localhost:3000/"),
                               .dim("  ➜  press h + enter to show help")])
        default:
            Transcript(title: "logs", subtitle: "tail -f", icon: "text.alignleft",
                       lines: [.dim("14:22:01  info   canvas: layout 6 panes"),
                               .dim("14:22:01  info   divider drag start"),
                               .warning("14:22:02  warn   pty resize coalesced (33ms)"),
                               .dim("14:22:03  info   divider drag commit"),
                               .dim("14:22:07  info   pane closed, focus → 3")])
        }
    }
}

// MARK: - Factory

/// Builds placeholder surfaces, numbering them in creation order so previews and
/// screenshots are readable.
@MainActor
public final class PlaceholderPaneFactory {
    private var indices: [PaneID: Int] = [:]
    private var next = 1
    private let theme: TerminalTheme
    /// Records recovered from disk, so a restored pane comes back as the same pane rather
    /// than being renumbered into a different transcript.
    private var restored: [PaneID: PaneRecord]

    public init(theme: TerminalTheme = .dark, restoring records: [PaneID: PaneRecord] = [:]) {
        self.theme = theme
        self.restored = records
    }

    public func makeContent(for paneID: PaneID) -> PaneContent {
        // `tileState` is the tile's own opaque blob; for placeholders it is the transcript
        // variant, which is exactly the kind of thing a real tile will keep there.
        let index: Int
        if let record = restored[paneID], let state = record.tileState,
           let stored = try? JSONDecoder().decode(Int.self, from: state) {
            index = stored
        } else {
            index = indices[paneID] ?? {
                defer { next += 1 }
                indices[paneID] = next
                return next
            }()
        }

        let transcript = Transcript.fixture(index)
        let view = NSHostingView(rootView: TerminalPlaceholderView(theme: theme,
                                                                   transcript: transcript))
        view.focusRingType = .none
        return PaneContent(view: view,
                           record: PaneRecord(kind: .placeholder,
                                              title: transcript.title,
                                              subtitle: transcript.subtitle,
                                              icon: transcript.icon,
                                              tileState: try? JSONEncoder().encode(index)))
    }
}

extension LayoutStore {
    /// A store wired to placeholder panes — used by every canvas preview.
    public static func placeholders(_ fixture: LayoutTree.Fixture,
                                    theme: TerminalTheme = .dark) -> LayoutStore {
        let factory = PlaceholderPaneFactory(theme: theme)
        return LayoutStore(tree: .fixture(fixture), theme: theme) { factory.makeContent(for: $0) }
    }

    /// Reopen a saved workspace, or start a fresh one. The tree and frames are restored
    /// synchronously so the window appears in its final geometry with no visible reflow.
    public static func restored(from storage: WorkspaceStorage,
                                theme: TerminalTheme = .dark,
                                fallback: LayoutTree.Fixture = .single,
                                title: String,
                                subtitle: String?) -> LayoutStore {
        let document = storage.loadAll().first
        if LayoutStore.isTracing {
            FileHandle.standardError.write(Data(
                "[ultra] restore: \(document.map { "\($0.tree.paneCount) panes" } ?? "nothing")\n".utf8))
        }
        let records: [PaneID: PaneRecord] = document.map { document in
            Dictionary(uniqueKeysWithValues: document.panes.compactMap { key, value in
                PaneID(uuidString: key).map { ($0, value) }
            })
        } ?? [:]

        let factory = PlaceholderPaneFactory(theme: theme, restoring: records)
        let store = LayoutStore(tree: document?.tree ?? .fixture(fallback),
                                theme: theme,
                                workspaceID: document?.id ?? UUID(),
                                storage: storage) { factory.makeContent(for: $0) }
        store.workspaceTitle = document?.title ?? title
        store.workspaceSubtitle = document?.subtitle ?? subtitle
        store.windowFrame = document?.windowFrame?.rect
        return store
    }
}

#Preview("Terminal pane", traits: .fixedLayout(width: 420, height: 240)) {
    TerminalPlaceholderView(theme: .dark, transcript: .fixture(1))
}

#Preview("Terminal pane — agent", traits: .fixedLayout(width: 420, height: 240)) {
    TerminalPlaceholderView(theme: .dark, transcript: .fixture(2))
}

#Preview("Terminal pane — light theme", traits: .fixedLayout(width: 420, height: 240)) {
    TerminalPlaceholderView(theme: .light, transcript: .fixture(3))
}
