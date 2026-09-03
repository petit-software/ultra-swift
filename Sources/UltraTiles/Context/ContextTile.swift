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
                EmptyTileState(icon: "paperclip", title: "Drop files or folders here")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { item in
                            ContextRow(item: item,
                                       remove: { model.remove(item) },
                                       togglePin: { model.togglePin(item) },
                                       reveal: { context.revealInFinder(item.url) },
                                       send: {
                                           context.injectIntoShell(
                                            ContextModel.reference(for: item,
                                                                   relativeTo: context.root))
                                       })
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tileScrollBar()
            }
        }
        .tileFooter { footer }
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
            // Dropping from Finder is the fast path and stays the headline — see the empty
            // state — but a drop needs two windows arranged just so. This is the same verb
            // for whoever has the tile in front of them and Finder behind something else.
            TileFooterButton(symbol: "plus", help: "Add files or folders…") {
                addFromFinder()
            }
            TileFooterButton(symbol: "arrow.right.to.line", help: "Type @references at the prompt, without submitting",
                             isEnabled: !model.items.isEmpty) {
                context.injectIntoShell(model.referenceText(relativeTo: context.root))
            }
            // `minus.circle` rather than a trash can: nothing is deleted from disk here, a
            // row is taken off a list — the same verb each row's own minus performs, in the
            // plural, which is what the ring around it says.
            TileFooterButton(symbol: "minus.circle", help: "Clear everything except pinned items",
                             isEnabled: !model.items.allSatisfy(\.isPinned)) {
                model.removeAllUnpinned()
            }
            TileStoreMenu(path: model.storeURL.path,
                          help: "Where this list is stored",
                          choose: chooseLocation,
                          reset: { model.resetLocation() })
        }
    }

    /// Adds whatever the panel returns, and silently skips what is already on the list —
    /// `add` answers that, and a duplicate is not an error worth a dialog.
    private func addFromFinder() {
        for url in chooseTileItems(title: "Add to Context", directory: context.root) {
            _ = model.add(url)
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
    let send: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(item.isMissing ? Token.Colour.tertiaryLabel : Token.Colour.accent)
                .frame(width: 14)

            Text(item.name)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(item.isMissing ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .strikethrough(item.isMissing)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // Opposite side rather than underneath, and the same size as the name — a file
            // and its weight are one fact, and setting the weight in small type made every
            // row read as a title with a caption. Only colour separates them now.
            //
            // "missing" keeps its warning colour: that is a STATE, not the secondary half of
            // anything, and it is the one thing in this tile worth interrupting a scan for.
            Group {
                if item.isMissing {
                    Text("missing")
                        .foregroundStyle(.orange)
                } else {
                    Text("~\(item.tokens / 1000 > 0 ? "\(item.tokens / 1000)k" : "\(item.tokens)")")
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                }
            }
            .font(Token.Type_.tileSubtitle.monospacedDigit())
            .lineLimit(1)
            // Never the side that truncates. Two flexible labels in one row shrink
            // together, and "~12k" losing its tail is a number that now reads wrong
            // rather than one that reads clipped — the name gives up the space instead,
            // which is what its middle truncation is already there to do.
            .layoutPriority(1)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Token.Colour.accent)
            }

            // Always laid out, only faded. A cluster that arrives on hover — and a weight
            // that leaves to make room for it — moves the name, the number and the pin
            // sideways, and a row that moves under the pointer is a row you cannot aim at.
            HStack(spacing: 7) {
                // The tile's headline verb, per row. The footer sends the WHOLE list, which
                // is the wrong granularity for most prompts: a list gathered over a session
                // holds far more than the one file the next sentence is about.
                //
                // Leads the cluster because it is the thing this tile is for; a missing file
                // has no reference worth typing, so it is dimmed rather than dropped — a
                // cluster that changes width between rows is a cluster you cannot aim at.
                Button(action: send) { Image(systemName: "arrow.right.to.line") }
                    .help("Send this file to the shell")
                    .disabled(item.isMissing)
                Button(action: togglePin) {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                }
                .help(item.isPinned ? "Unpin" : "Pin — survives Clear")
                Button(action: reveal) { Image(systemName: "magnifyingglass") }
                    .help("Reveal in Finder")
                // Circled minus, not a cross or a trash can. Removing a row takes the file
                // off this list and does nothing to the file, and a trash can promises
                // otherwise; the circle matches the footer's Clear and the Git pane's Unstage,
                // which perform the same verb.
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .help("Remove from list")
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

#Preview("Context", traits: .fixedLayout(width: 340, height: 320)) {
    ContextTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
