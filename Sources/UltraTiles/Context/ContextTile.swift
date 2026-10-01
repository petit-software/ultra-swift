import AppKit
import QuickLookThumbnailing
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
                    LazyVStack(alignment: .leading, spacing: ContextCard.spacing) {
                        ForEach(model.items) { item in
                            ContextCard(item: item,
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
                    .padding(.horizontal, ContextCard.inset)
                    .padding(.vertical, ContextCard.spacing)
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
        TileFooter(summary: "~\(ContextModel.Item.compact(model.totalTokens)) tokens",
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
}

/// One item, in its own rounded, bordered card: a thumbnail of the file, its name, and
/// under the name what kind of file it is, how big, and roughly what it costs.
///
/// A card rather than a row because an item here is a THING the user picked up and put
/// down, not a line in a listing — and three facts about it do not fit on one line of a
/// narrow tile without one of them giving way. Every card is the same height, thumbnail
/// or not, so a list of mixed files does not ripple as previews arrive.
private struct ContextCard: View {
    static let height: CGFloat = 56
    static let spacing: CGFloat = 6
    static let inset: CGFloat = 8
    static let radius: CGFloat = 8
    static let thumbnailSide: CGFloat = 40

    let item: ContextModel.Item
    let remove: () -> Void
    let togglePin: () -> Void
    let reveal: () -> Void
    let send: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ContextThumbnail(url: item.url, isDirectory: item.isDirectory,
                             isMissing: item.isMissing, side: Self.thumbnailSide)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(item.isMissing ? Token.Colour.tertiaryLabel : Token.Colour.label)
                    .strikethrough(item.isMissing)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // "missing" keeps its warning colour: that is a STATE, not a measurement, and
                // it is the one thing in this tile worth interrupting a scan for.
                HStack(spacing: 5) {
                    if item.isMissing {
                        Text("missing").foregroundStyle(.orange)
                    } else {
                        ContextKindBadge(kind: item.kind)
                        Text(captionAfterKind)
                            .foregroundStyle(Token.Colour.tertiaryLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(Token.Type_.monoSmall.monospacedDigit())
            }

            Spacer(minLength: 8)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Token.Colour.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same treatment as the chat's changed-files table: a faint wash inside a
        // hairline, rounded. Two tiles that both show "files, as cards" should look like
        // the same idea.
        .background(Token.Colour.label.opacity(isHovering ? 0.06 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(Token.Colour.separator, lineWidth: 1))
        // Floating over the card's trailing end — see `tileHoverControls`. Over the pin and
        // the caption's tail, on demand, so the card is the same shape hovered or not.
        .tileHoverControls(isHovering, offset: CGSize(width: -8, height: 0)) {
            HStack(spacing: 7) {
                // The tile's headline verb, per item. The footer sends the WHOLE list, which
                // is the wrong granularity for most prompts: a list gathered over a session
                // holds far more than the one file the next sentence is about.
                //
                // Leads the cluster because it is the thing this tile is for; a missing file
                // has no reference worth typing, so it is dimmed rather than dropped — a
                // cluster that changes width between cards is a cluster you cannot aim at.
                Button(action: send) { Image(systemName: "arrow.right.to.line") }
                    .help("Send this file to the shell")
                    .disabled(item.isMissing)
                Button(action: togglePin) {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                }
                .help(item.isPinned ? "Unpin" : "Pin — survives Clear")
                Button(action: reveal) { Image(systemName: "magnifyingglass") }
                    .help("Reveal in Finder")
                // Circled minus, not a cross or a trash can. Removing a card takes the file
                // off this list and does nothing to the file, and a trash can promises
                // otherwise; the circle matches the footer's Clear and the Git pane's Unstage,
                // which perform the same verb.
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .help("Remove from list")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isMissing
                            ? "\(item.name), missing"
                            : "\(item.name), \(item.caption), tokens")
    }

    /// The caption with its first part — the kind — taken off, because the kind is drawn
    /// as a badge and the rest as text. One source for both, so the accessibility label
    /// and the picture say the same thing.
    private var captionAfterKind: String {
        let parts = item.caption.components(separatedBy: " · ")
        return parts.dropFirst().joined(separator: " · ")
    }
}

/// The item's type, set in a small capsule — `MD`, `SWIFT`, `Folder` — so the eye can
/// pick out "the Swift files" from a mixed list before reading a single name.
private struct ContextKindBadge: View {
    let kind: String

    var body: some View {
        Text(kind)
            .font(Token.Type_.monoSmall.weight(.medium))
            .foregroundStyle(Token.Colour.secondaryLabel)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Token.Colour.label.opacity(0.08), in: .capsule)
    }
}

/// A picture of the file: QuickLook's thumbnail — the first page of a document, the
/// image itself, the opening lines of a source file — and the file's icon until that
/// arrives, or for good when QuickLook has nothing to say about the type.
///
/// The icon is drawn FIRST, synchronously, so no card ever shows an empty square; the
/// thumbnail replaces it in place. Both sit in the same rounded, bordered frame, so a
/// folder's icon and a photo's preview are the same shape in the list.
private struct ContextThumbnail: View {
    let url: URL
    let isDirectory: Bool
    let isMissing: Bool
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var preview: CGImage?

    var body: some View {
        Group {
            if let preview {
                Image(decorative: preview, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .frame(width: side, height: side)
        .background(Token.Colour.label.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Token.Colour.separator, lineWidth: 1))
        .opacity(isMissing ? 0.4 : 1)
        .task(id: url) {
            preview = nil
            guard !isMissing, !isDirectory else { return }
            preview = await Self.thumbnail(for: url, side: side, scale: displayScale)
        }
        .accessibilityHidden(true)
    }

    /// The icon Finder would show — the right one for the extension, or the generic
    /// document when the file is gone and nothing can be asked of it.
    private var icon: NSImage {
        isMissing
            ? NSWorkspace.shared.icon(for: isDirectory ? .folder : .data)
            : NSWorkspace.shared.icon(forFile: url.path)
    }

    /// QuickLook's best picture of the file at this size, or nothing. Off the main actor
    /// for the whole of the wait: the generator renders documents, and a list of twenty
    /// PDFs must not stall the pane while it does.
    nonisolated static func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: side, height: side),
                                                   scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request).cgImage
    }
}

#Preview("Context", traits: .fixedLayout(width: 340, height: 320)) {
    ContextTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
