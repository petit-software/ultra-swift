import AppKit
import SwiftUI
import UltraDesign
import UniformTypeIdentifiers

/// Files and folders gathered for the agent in the next pane.
public struct ContextTile: View {
    @State private var model: ContextModel
    @State private var isTargeted = false
    private let context: TileContext

    public init(context: TileContext) {
        self.context = context
        _model = State(initialValue: ContextModel(root: context.root))
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                EmptyTileState(icon: "paperclip",
                               title: "Drop files or folders here",
                               detail: "From Finder, or any pane")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { item in
                            ContextRow(item: item,
                                       remove: { model.remove(item) },
                                       togglePin: { model.togglePin(item) },
                                       reveal: { context.revealInFinder(item.url) })
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tileScrollBar()
            }
        }
        .background(Token.Colour.paneBackground)
        .tileFooter { footer }
        .tileHeaderInset()
        // The whole tile is the drop target, not a small well inside it — a drop zone you
        // have to aim at is a drop zone people miss.
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where model.add(url) { added = true }
            return added
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Token.Space.paneRadius, style: .continuous)
                    .strokeBorder(Token.Colour.accent, lineWidth: 2)
                    .background(Token.Colour.accentWash)
                    .allowsHitTesting(false)
            }
        }
        .animation(Token.Motion.structuralRespectingPreferences, value: isTargeted)
    }

    private var footer: some View {
        TileFooter(summary: "~\(formatted(model.totalTokens)) tokens",
                   // Deliberately approximate, and labelled so: an exact-looking number
                   // here would be a lie, because the real tokeniser is the model's.
                   summaryHelp: "Rough estimate — bytes ÷ 4") {
            TileFooterButton(symbol: "arrow.right.to.line", help: "Type @references at the prompt, without submitting",
                             isEnabled: !model.items.isEmpty) {
                context.injectIntoShell(model.referenceText(relativeTo: context.root))
            }
            TileFooterButton(symbol: "trash", help: "Clear everything except pinned items",
                             isEnabled: !model.items.allSatisfy(\.isPinned)) {
                model.removeAllUnpinned()
            }
            TileStoreMenu(path: model.storeURL.path,
                          help: "Where this list is stored",
                          choose: chooseLocation,
                          reset: { model.resetLocation() })
        }
    }

    private func chooseLocation() {
        guard let url = chooseTileFile(title: "Context List Location",
                                       suggestedName: model.storeURL.lastPathComponent,
                                       directory: context.root,
                                       allowedExtensions: ["json"])
        else { return }
        model.relocate(to: url)
    }

    private func formatted(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : String(value)
    }
}

private struct ContextRow: View {
    let item: ContextModel.Item
    let remove: () -> Void
    let togglePin: () -> Void
    let reveal: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(item.isMissing ? Token.Colour.tertiaryLabel : Token.Colour.accent)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(item.isMissing ? Token.Colour.tertiaryLabel : Token.Colour.label)
                    .strikethrough(item.isMissing)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isMissing {
                    Text("missing")
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(.orange)
                } else {
                    Text("~\(item.tokens / 1000 > 0 ? "\(item.tokens / 1000)k" : "\(item.tokens)")")
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                }
            }
            Spacer(minLength: 0)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Token.Colour.accent)
            }
            if isHovering {
                Button(action: togglePin) {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                }
                .help(item.isPinned ? "Unpin" : "Pin — survives Clear")
                Button(action: reveal) { Image(systemName: "magnifyingglass") }
                    .help("Reveal in Finder")
                Button(action: remove) { Image(systemName: "xmark") }
                    .help("Remove")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

#Preview("Context", traits: .fixedLayout(width: 340, height: 320)) {
    ContextTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
