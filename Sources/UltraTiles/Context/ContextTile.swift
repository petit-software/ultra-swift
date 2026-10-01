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
                    LazyVStack(alignment: .leading, spacing: ContextRow.spacing) {
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
                    .padding(.horizontal, ContextRow.inset)
                    .padding(.vertical, ContextRow.spacing)
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

/// One item, as a row: a thumbnail of the file, its name with the pin beside it, under the
/// name what kind of file it is and roughly what it costs, and its size in a column of its
/// own on the trailing side, centred on the row, where a number is easiest to compare down
/// a list.
///
/// A row, not a card. It was a bordered card around a bordered thumbnail around a capsule
/// badge — three frames deep for one file — and the frames said more than the file did. Now
/// the only enclosure is a wash under the pointer, so the row is plain until it is the one
/// being reached for. The meta line is the system face, not mono: these are a few words and
/// a number to glance at, not a path to read. Every row is the same height, thumbnail or
/// not, so a list of mixed files does not ripple as previews arrive.
private struct ContextRow: View {
    static let height: CGFloat = 56
    static let spacing: CGFloat = 2
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
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(Token.Type_.tileSubtitle)
                        .foregroundStyle(item.isMissing ? Token.Colour.tertiaryLabel : Token.Colour.label)
                        .strikethrough(item.isMissing)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Token.Colour.accent)
                    }
                }

                // "missing" keeps its warning colour: that is a STATE, not a measurement, and
                // it is the one thing in this tile worth interrupting a scan for.
                Group {
                    if item.isMissing {
                        Text("missing").foregroundStyle(.orange)
                    } else {
                        Text(details)
                            .foregroundStyle(Token.Colour.secondaryLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 12))
            }

            // Its own column, centred on the row rather than sat on the meta line: the
            // size belongs to the whole item, and a number at the row's middle lines up
            // with the thumbnail and reads down a list in one straight run.
            if !item.isMissing {
                Spacer(minLength: 8)
                Text(item.sizeText)
                    .font(.system(size: 12))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The one enclosure, and only under the pointer: a wash, no hairline. A border on
        // every row made a list of boxes; a wash on the hovered one says "this row" and
        // nothing about the others.
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Token.Colour.label.opacity(0.06))
            }
        }
        // Floating over the row's trailing end — see `tileHoverControls`. Over the pin and
        // the size, on demand, so the row is the same shape hovered or not.
        .tileHoverControls(isHovering, offset: CGSize(width: -8, height: 0)) {
            HStack(spacing: 7) {
                // The tile's headline verb, per item. The footer sends the WHOLE list, which
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
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .contentShape(.rect)
        // The row itself is the verb: one click sends the file to the shell, the thing this
        // tile is for, so the common case needs no aim at a pill that has not appeared yet;
        // two clicks show it in Finder, the way two clicks open a thing anywhere on the Mac.
        // Double first, so a second click is read as the pair and not as two sends. A
        // missing file has no reference to type and nothing for Finder to show, so neither
        // does anything — the pill's own controls are dimmed to say the same.
        .onTapGesture(count: 2) { if !item.isMissing { reveal() } }
        .onTapGesture { if !item.isMissing { send() } }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isMissing
                            ? "\(item.name), missing"
                            : "\(item.name), \(item.caption), tokens")
    }

    /// The meta line's leading part: the kind, a folder's file count, and the token
    /// estimate — `item.caption` without the size, which has moved to the trailing end.
    /// Same spellings as the caption, so the picture and the accessibility label agree.
    private var details: String {
        var parts = [item.kind]
        if let count = item.fileCount { parts.append(count == 1 ? "1 file" : "\(count) files") }
        parts.append("~" + ContextModel.Item.compact(item.tokens))
        return parts.joined(separator: " · ")
    }
}

/// A picture of the file: QuickLook's thumbnail — the first page of a document, the
/// image itself, the opening lines of a source file — and the file's icon until that
/// arrives, or for good when QuickLook has nothing to say about the type.
///
/// The icon is drawn FIRST, synchronously, so no row ever shows an empty square; the
/// thumbnail replaces it in place, in the same square, so a folder's icon and a photo's
/// preview take the same room in the list.
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
        // Clipped, not framed: a preview's corners are rounded so a page of text does not
        // land as a hard rectangle, but there is no wash or hairline around it — the row
        // supplies the one enclosure, and an icon needs none.
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
