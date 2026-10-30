import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UltraDesign
import UniformTypeIdentifiers

/// Files and folders gathered for the agent in the next pane.
///
/// A click selects a row, the way a click selects a file in Finder; Space then shows it in
/// Quick Look and a double click sends its `@path` to the shell. The keys are handled by
/// `ContextHostingView`, which is the pane's first responder when it is focused.
public struct ContextTile: View {
    let model: ContextModel
    @State private var isTargeted = false
    let context: TileContext
    /// Where each row is, for the Quick Look panel to zoom out of. See `ContextRowFrames`.
    let frames = ContextRowFrames()

    public init(context: TileContext, model: ContextModel? = nil) {
        self.context = context
        self.model = model ?? ContextModel(root: context.root)
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
                                        isSelected: model.selection == item.id,
                                        select: { model.select(item) },
                                        remove: { model.remove(item) },
                                        togglePin: { model.togglePin(item) },
                                        reveal: { context.revealInFinder(item.url) },
                                        send: {
                                            context.injectIntoShell(
                                             ContextModel.reference(for: item,
                                                                    relativeTo: context.root))
                                        })
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    frames.rects[item.id] = $0
                                }
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
    let isSelected: Bool
    let select: () -> Void
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
                            .foregroundStyle(Token.Colour.accentInk)
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
        // The one enclosure: a wash, no hairline. A border on every row made a list of
        // boxes; a wash on the hovered row says "this row" and nothing about the others,
        // and the accent's wash on the selected one says "this is the row Space previews
        // and ↩ sends" — the file tree's selection, so a selected file looks the same in
        // both tiles.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Token.Colour.accentWashStrong)
            } else if isHovering {
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
        // Finder's grammar: one click picks the row out, and Space then shows the file in
        // Quick Look; two clicks DO the thing, which here is sending the file to the shell,
        // the thing this tile is for. One click used to send, and a list you cannot look
        // at without typing into the prompt is a list you cannot look at. Double first, so
        // a second click is read as the pair and not as two selects. A missing file can
        // still be selected — to be removed by key, one day — but has no reference to type,
        // so the double click does nothing and the pill's send is dimmed to say the same.
        .onTapGesture(count: 2) { if !item.isMissing { send() } }
        .onTapGesture { select() }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// Where each row sits in the tile, by item, in the hosting view's coordinates.
///
/// The Quick Look panel zooms out of the thing it previews — the row's thumbnail in Finder —
/// and asks the delegate for that rectangle on screen. The rows know where they are and the
/// hosting view knows where the window is, so this is the handoff between them. A class
/// rather than state so that writing a frame does not redraw the list that reported it.
@MainActor
final class ContextRowFrames {
    var rects: [UUID: CGRect] = [:]
}

/// The pane's content, and its keyboard.
///
/// Takes the keyboard when the pane is focused — the canvas looks for the first view that
/// will — so the keys Finder gives a selected file work here: Space shows it in Quick Look,
/// ↑ and ↓ move the selection, ↩ sends the file to the shell. Plain keys, and deliberately
/// not menu items: they are what a list does when it has the keyboard, and the terminal is
/// not first responder while this pane is. The menu's Quick Look, ⌘Y, lands here too.
///
/// Also the Quick Look panel's controller. The panel finds its controller by walking the
/// responder chain from the key window's first responder, which is this view while the
/// pane is focused, and it asks the controller for the items and which one to show. Focus
/// moving to another pane takes the keyboard with it, and the panel closes: a preview that
/// floats over a terminal nobody asked it about is a preview in the way.
final class ContextHostingView: NSHostingView<ContextTile> {
    private let model: ContextModel
    private let context: TileContext
    private let frames: ContextRowFrames

    init(tile: ContextTile) {
        model = tile.model
        context = tile.context
        frames = tile.frames
        super.init(rootView: tile)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @available(*, unavailable)
    required init(rootView: ContextTile) { fatalError("use init(tile:)") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad).isEmpty
        else { return super.keyDown(with: event) }
        switch event.keyCode {
        case Self.spaceKey: toggleQuickLook()
        case Self.upKey: moveSelection(by: -1)
        case Self.downKey: moveSelection(by: 1)
        case Self.returnKey, Self.enterKey: sendSelection()
        default: super.keyDown(with: event)
        }
    }

    static let spaceKey: UInt16 = 49
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let upKey: UInt16 = 126
    static let downKey: UInt16 = 125

    // MARK: Verbs

    /// Show the selected file in Quick Look, or hide the panel if it is up. With nothing
    /// selected the first file is previewed, and selected, so the panel and the list agree.
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, controls(panel) {
            panel.orderOut(nil)
            return
        }
        guard !model.previewableItems.isEmpty else { NSSound.beep(); return }
        if model.selectedItem.map(\.isMissing) ?? true {
            model.select(model.previewableItems.first)
        }
        // The panel asks the key window's first responder to be its controller. The canvas
        // puts the keyboard here when the pane is focused, but a menu command can arrive
        // before that has happened, so make sure.
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        panel.makeKeyAndOrderFront(nil)
        showSelectionInPanel()
    }

    /// Whether Space would show something.
    var canQuickLook: Bool { !model.previewableItems.isEmpty }

    private func moveSelection(by offset: Int) {
        model.moveSelection(by: offset)
        showSelectionInPanel()
    }

    private func sendSelection() {
        guard let item = model.selectedItem, !item.isMissing else { NSSound.beep(); return }
        context.injectIntoShell(ContextModel.reference(for: item, relativeTo: context.root))
    }

    /// Keep the panel on the selected row. The panel's own index moves only here, so the
    /// list is the one source of truth for what is being looked at.
    private func showSelectionInPanel() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible, controls(panel),
              let index = model.previewableItems.firstIndex(where: { $0.id == model.selection })
        else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    // MARK: Quick Look panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    override func resignFirstResponder() -> Bool {
        // The keyboard is leaving this pane, and the preview goes with it. Checked for
        // existence first: asking for the shared panel creates it.
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
           panel.isVisible, controls(panel) {
            panel.orderOut(nil)
        }
        return super.resignFirstResponder()
    }

    /// Whether the panel is showing THIS pane's list. `currentController` is untyped.
    private func controls(_ panel: QLPreviewPanel) -> Bool {
        (panel.currentController as AnyObject?) === self
    }
}

// `@preconcurrency`: the panel calls its data source and delegate on the main thread,
// where the model lives, which the protocols predate saying; a call from elsewhere traps.
extension ContextHostingView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        model.previewableItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = model.previewableItems
        guard items.indices.contains(index) else { return nil }
        return items[index].url as NSURL
    }

    /// ↑ and ↓ while the panel is key move the list's selection, as they do in Finder, and
    /// the panel follows the list. Everything else is the panel's own.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case Self.upKey: moveSelection(by: -1); return true
        case Self.downKey: moveSelection(by: 1); return true
        default: return false
        }
    }

    /// The row's frame on screen, so the panel zooms out of the row and back into it.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item.previewItemURL,
              let row = model.previewableItems.first(where: { $0.url == url }),
              let rect = frames.rects[row.id], let window else { return .zero }
        // SwiftUI reports the frame in the hosting view's space with the origin at the top;
        // the hosting view is flipped, so the same numbers are AppKit's.
        return window.convertToScreen(convert(rect, to: nil))
    }
}

#Preview("Context", traits: .fixedLayout(width: 340, height: 320)) {
    ContextTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
