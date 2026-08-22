import AppKit
import SwiftUI
import UltraDesign

/// A minimal text editor in a pane.
public struct EditorTile: View {
    @State private var document: EditorDocument
    private let context: TileContext

    public init(context: TileContext, file: URL? = nil) {
        self.context = context
        _document = State(initialValue: file.map(EditorDocument.init(url:)) ?? EditorDocument())
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = document.notice { noticeBar(notice) }

            if document.url == nil {
                EmptyTileState(icon: "doc.text",
                               title: "No file open",
                               detail: "Open one, or click a file in a File Tree pane")
                    .overlay(alignment: .bottom) {
                        Button("Open File…") { openPanel() }
                            .padding(.bottom, 26)
                    }
            } else if document.isBinary {
                EmptyTileState(icon: "doc.questionmark",
                               title: "Not a text file",
                               detail: document.displayName)
            } else {
                CodeTextView(text: $document.text, onSave: { document.save() })
            }

        }
        .background(Token.Colour.paneBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .tileHeaderInset()
    }

    private var footer: some View {
        // Controls lead, status trails — the same order as every other tile. This footer
        // used to run the other way round, which is why the shared one exists.
        TileFooter(summary: document.url.map { TileFactory.abbreviate($0.path) } ?? "No file",
                   truncation: .head) {
            TileFooterButton(symbol: "folder", help: "Open another file") { openPanel() }
            if document.url != nil, !document.isBinary {
                TileFooterButton(symbol: "square.and.arrow.down", help: "Save (⌘S)",
                                 isEnabled: document.isDirty) { document.save() }
            }
            if document.isDirty {
                Circle()
                    .fill(Token.Colour.accent)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
    }

    @ViewBuilder
    private func noticeBar(_ notice: EditorDocument.Notice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: notice))
            Text(message(for: notice)).lineLimit(2)
            Spacer(minLength: 4)
            if notice == .conflict {
                // Both ways out, named for what they do to YOUR edits.
                Button("Keep Mine") { document.dismissNotice() }
                Button("Reload") { document.revert(); document.externalChange() }
            } else {
                Button("Dismiss") { document.dismissNotice() }
            }
        }
        .buttonStyle(.plain)
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(notice == .conflict
                    ? Color.orange.opacity(0.18)
                    : Token.Colour.accent.opacity(0.12))
    }

    private func icon(for notice: EditorDocument.Notice) -> String {
        switch notice {
        case .reloadedFromDisk: "arrow.clockwise"
        case .conflict: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon"
        }
    }

    private func message(for notice: EditorDocument.Notice) -> String {
        switch notice {
        case .reloadedFromDisk: "Reloaded — the file changed on disk"
        case .conflict: "Changed on disk while you were editing. Nothing was overwritten."
        case .failed(let reason): reason
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = context.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.open(url)
    }
}

#Preview("Editor", traits: .fixedLayout(width: 460, height: 380)) {
    EditorTile(context: .inert())
}
