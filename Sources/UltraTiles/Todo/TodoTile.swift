import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UltraDesign

/// The project's todo list, as a file.
public struct TodoTile: View {
    @State private var store: TodoStore
    @State private var draft: String = ""
    @State private var draftFocused = false
    /// The row a drag is currently over, so the insertion line follows the pointer.
    @State private var dropTarget: Int?
    /// The task being edited, if any.
    ///
    /// Held HERE rather than in the row, so that opening one editor closes the last. Two
    /// rows in edit mode at once is two drafts of a list that has one file behind it.
    @State private var editingID: Int?
    /// The section new tasks go to, or nil for the top of the list.
    ///
    /// By TITLE, not by line: every edit renumbers the lines, and the file is also edited
    /// from outside this pane. A title that no longer matches anything is simply nil again —
    /// see `target`.
    @State private var targetSection: String?
    private let context: TileContext

    public init(context: TileContext) {
        self.context = context
        _store = State(initialValue: TodoStore(root: context.root))
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = store.notice { noticeBar(notice) }
            composer
            list
        }
        .tileFooter { footer }
    }

    @ViewBuilder
    private var list: some View {
        // Groups, not tasks: a list whose only content is a section made a moment ago is
        // not empty, and saying "No tasks yet" over it would hide the thing just made.
        if store.document.grouped.isEmpty {
            // The path used to be repeated here, and the answer this tile reached — the
            // footer carries it, in every state rather than only the empty one — is now the
            // rule for all of them. So this is `EmptyTileState` rather than a copy of it.
            EmptyTileState(icon: "checklist",
                           title: store.exists ? "No tasks yet"
                                               : "No list in this project yet")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.document.grouped) { group in
                        // Not every heading earns a row — see `showsHeading(of:)`.
                        if let heading = group.heading, store.document.showsHeading(of: group) {
                            TodoHeadingRow(heading: heading,
                                           isTarget: target == heading.title,
                                           isDropTarget: dropTarget == heading.id,
                                           isEditing: editingID == heading.id,
                                           select: { toggleTarget(heading.title) },
                                           delete: { remove(heading) },
                                           beginEdit: { editingID = heading.id },
                                           commitEdit: { text in commitEdit(text, for: heading) },
                                           cancelEdit: { editingID = nil },
                                           // INTO the section, at its head — the line after
                                           // the heading. "Before the heading" is the end of
                                           // the section above, which the rows there say.
                                           onDrop: { moved in
                                               dropTarget = nil
                                               store.move(moved, before: heading.id + 1)
                                           },
                                           onDragOver: { dropTarget = $0 ? heading.id : nil })
                        }
                        ForEach(group.items) { item in
                            TodoRow(item: item,
                                    isDropTarget: dropTarget == item.id,
                                    isEditing: editingID == item.id,
                                    toggle: { store.toggle(item.id) },
                                    send: { context.injectIntoShell(item.text) },
                                    delete: { store.removeItem(item.id) },
                                    beginEdit: { editingID = item.id },
                                    commitEdit: { text in commitEdit(text, for: item) },
                                    cancelEdit: { editingID = nil },
                                    onDropBefore: { moved in
                                        dropTarget = nil
                                        store.move(moved, before: item.id)
                                    },
                                    onDragOver: { dropTarget = $0 ? item.id : nil })
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .tileScrollBar()
        }
    }

    /// The section the composer is pointed at, if it still exists.
    private var target: String? {
        guard let targetSection, store.document.sections.contains(targetSection) else { return nil }
        return targetSection
    }

    private func toggleTarget(_ title: String) {
        targetSection = target == title ? nil : title
        draftFocused = true
    }

    /// The add field, sitting at the head of the list.
    ///
    /// At the top rather than the bottom because that is where the new task lands, and a
    /// composer that writes to the opposite end of the list from where it sits makes you
    /// hunt for what you just typed.
    ///
    /// A PILL, inset from the pane on both sides, with nothing but the words in it. It was
    /// dressed as a row — a plus where a task's circle goes, a hairline around it — and read
    /// as a row with decorations rather than as the one place in the pane you type. The
    /// fill alone says "input"; the border said it a second time and boxed the pill in.
    private var composer: some View {
        HStack(alignment: .center, spacing: 6) {
            // Not a `TextField`: see `SingleLineField` for the point the placeholder jumped
            // on every click.
            //
            // The placeholder is the whole manual for sections: it says where a task will
            // go, and that `#` is how a section is made or chosen.
            SingleLineField(placeholder: target.map { "Add a task to \($0)" }
                                         ?? "Add a task, or # for a section",
                            text: $draft, isFocused: $draftFocused, onSubmit: add)

            // The slot is always here; only the glyph inside it comes and goes. Appearing
            // and disappearing, the button changed the composer's height as well as its
            // width, so the first character typed nudged the whole list below it — and the
            // moment the task landed and the draft emptied, nudged it back.
            TodoRowSlot {
                Button(action: add) { Image(systemName: "return") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.accent)
                    .help(TodoDocument.sectionDraft(draft) == nil ? "Add task" : "Add section")
                    .opacity(draft.isEmpty ? 0 : 1)
                    .disabled(draft.isEmpty)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Token.Colour.label.opacity(draftFocused ? 0.09 : 0.06))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .contentShape(.rect)
        // Clicking anywhere along the field starts typing, the way clicking a task row hits
        // its whole width rather than just the words.
        .onTapGesture { draftFocused = true }
        .animation(Token.Motion.chromeFade, value: draftFocused)
    }

    private var footer: some View {
        TileFooter(summary: TileFactory.abbreviate(store.url.path), truncation: .head) {
            TileStoreMenu(path: store.url.path,
                          help: "Where this list is stored",
                          choose: chooseLocation,
                          reset: { store.resetLocation() })
        }
    }

    private func chooseLocation() {
        guard let url = chooseTileFile(title: "Todo List Location",
                                       suggestedName: store.url.lastPathComponent,
                                       directory: context.root,
                                       allowedExtensions: ["md", "markdown", "txt"])
        else { return }
        store.relocate(to: url)
    }

    /// A draft that starts with `#` is about SECTIONS; anything else is a task.
    ///
    /// `# Later` makes the section — or, when there already is one by that name, points the
    /// composer at it instead of making a twin. Either way the tasks typed next go there,
    /// which is what someone who has just named a section is about to do. A bare `#` points
    /// it back at the top. That is the whole keyboard path: no row has to be clicked.
    private func add() {
        if let section = TodoDocument.sectionDraft(draft) {
            if section.title.isEmpty {
                targetSection = nil
            } else {
                // Matched the way a person would, not the way `==` would.
                let existing = store.document.sections.first {
                    $0.caseInsensitiveCompare(section.title) == .orderedSame
                }
                if existing == nil { store.addSection(section.title, level: section.level) }
                targetSection = existing ?? section.title
            }
        } else if let target {
            store.prependItem(draft, to: target)
        } else {
            store.prependItem(draft)
        }
        draft = ""
        // Focus is kept so several tasks can be typed in a row without reaching for the
        // mouse between them.
        draftFocused = true
    }

    /// Write an edited task back, and leave edit mode either way.
    ///
    /// An empty result REMOVES the task. It used to revert, on the theory that clearing a
    /// field is a slip on the way to retyping — but a slip is abandoned with Escape, which
    /// reverts, and pressing Return on a field you have deliberately emptied is the one
    /// gesture that says "this line should not be here". Keeping an empty task alive after
    /// it meant the only way out was the remove control on a row that already said nothing.
    private func commitEdit(_ text: String, for item: TodoDocument.Item) {
        editingID = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            store.removeItem(item.id)
            return
        }
        guard trimmed != item.text else { return }
        store.setText(trimmed, for: item.id)
    }

    /// A heading follows the same rule as a task: Return on an emptied field removes it.
    private func commitEdit(_ text: String, for heading: TodoDocument.Heading) {
        editingID = nil
        // Hashes typed into the field are not part of the name; the level is kept.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let title = TodoDocument.sectionDraft(trimmed)?.title ?? trimmed
        guard !title.isEmpty else { remove(heading); return }
        guard title != heading.title else { return }
        if targetSection == heading.title { targetSection = title }
        store.setHeading(title, for: heading.id)
    }

    /// The heading line only. Its tasks stay and join the section above.
    private func remove(_ heading: TodoDocument.Heading) {
        if targetSection == heading.title { targetSection = nil }
        store.removeHeading(heading.id)
    }

    private func noticeBar(_ notice: TodoStore.Notice) -> some View {
        NoticeBar(symbol: notice == .reloadedFromDisk
                          ? "arrow.clockwise.circle.fill" : "exclamationmark.triangle.fill",
                  message: message(for: notice),
                  dismiss: { store.dismissNotice() })
    }

    private func message(for notice: TodoStore.Notice) -> String {
        switch notice {
        case .reloadedFromDisk: "Reloaded — the file changed on disk"
        case .failed(let reason): "Could not save: \(reason)"
        }
    }
}

private struct TodoRow: View {
    let item: TodoDocument.Item
    /// A line is drawn where the task would land. An insertion point, not a highlight on the
    /// row: "before this one" is the thing being chosen, and a filled row cannot say that.
    let isDropTarget: Bool
    let isEditing: Bool
    let toggle: () -> Void
    let send: () -> Void
    let delete: () -> Void
    let beginEdit: () -> Void
    let commitEdit: (String) -> Void
    let cancelEdit: () -> Void
    let onDropBefore: (Int) -> Void
    let onDragOver: (Bool) -> Void
    @State private var isHovering = false
    /// The text being edited. Seeded from the task when the field appears and thrown away
    /// with it, so a cancelled edit leaves nothing behind to leak into the next one.
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        // While editing, the row must NOT be draggable: the field owns the pointer, and a
        // drag that begins on a text selection would carry the task away mid-edit.
        if isEditing {
            row
        } else {
            // The whole row is the handle. A todo list is short and the rows are small; a
            // separate grip would be a smaller target for no gain.
            row.draggable(TodoDragPayload(id: item.id)) {
                Text(item.text)
                    .font(Token.Type_.tileSubtitle)
                    .padding(6)
                    .background(Token.Colour.tileBackground)
            }
        }
    }

    private var row: some View {
        // ONE alignment, in both modes. It used to centre while editing and sit on the first
        // text baseline otherwise, so clicking the pencil nudged the circle and the controls
        // a couple of points down the row — a jump on a row you are about to type into.
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button(action: toggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    // A done task is GREYED, glyph and text alike: the filled check is what
                    // says "done", it does not need the accent to say it louder. It wore the
                    // accent, and the accent ships as white — which on a light pane is a
                    // white disc on a white surface, a task with no checkbox at all.
                    .foregroundStyle(Token.Colour.tertiaryLabel)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(isEditing)

            // The LABEL gives the row its height in both modes, and the field is laid over
            // it rather than swapped in for it.
            //
            // A plain text field carries a point or so of chrome a `Text` does not, so the
            // swap grew the row as an edit opened and shrank it again on commit — every
            // task below the one being edited sliding a pixel each way. An overlay takes no
            // part in layout, so the row measures the same whether it is being read or
            // typed into, and the field paints in exactly the label's column.
            Text(item.text)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(item.isDone ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .strikethrough(item.isDone, color: Token.Colour.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                // Takes the row's free width itself, in place of the trailing spacer it
                // used to share it with — the field over it has to span the row, not stop
                // at the end of a three-word task.
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isEditing ? 0 : 1)
                // Double-click to edit, the way a filename is renamed in Finder. The
                // pencil below is the discoverable route; this is the fast one.
                .onTapGesture(count: 2, perform: beginEdit)
                .overlay(alignment: .topLeading) {
                    if isEditing {
                        // Deliberately the same font, colour and column as the label it
                        // covers, so the row is edited in place rather than replaced by a
                        // form.
                        TextField("Task", text: $draft)
                            .textFieldStyle(.plain)
                            .font(Token.Type_.tileSubtitle)
                            .foregroundStyle(Token.Colour.label)
                            .focused($isFieldFocused)
                            .onSubmit { commitEdit(draft) }
                            // Escape abandons the edit. Without it the only way out of the
                            // field is to accept whatever is in it, which makes a mistyped
                            // task a trap.
                            .onExitCommand(perform: cancelEdit)
                            .task {
                                draft = item.text
                                isFieldFocused = true
                            }
                    }
                }
        }
        // The controls float over the row's trailing end — see `tileHoverControls` for why
        // they are no longer a column of the `HStack`. Top-aligned rather than centred so
        // they sit on the FIRST line of a task, whether it has one line or four.
        //
        // Three slots, always the same three columns, whatever is in them. The cluster used
        // to carry three controls on hover and a single one while editing, so pressing the
        // pencil re-flowed it and every icon landed somewhere else — including under the
        // pointer that had just pressed one.
        //
        // Raised by the pill's own vertical padding, so it is the GLYPHS that sit on the
        // first line, not the top of the glass around them.
        .tileHoverControls(isHovering || isEditing, alignment: .topTrailing,
                           offset: CGSize(width: 0, height: -3)) {
                HStack(spacing: 4) {
                    TodoRowSlot {
                        // Save takes the PENCIL's slot: it is the same verb at its other end —
                        // one opens the edit, one closes it — so the column keeps its meaning.
                        if isEditing {
                            Button { commitEdit(draft) } label: { Image(systemName: "return") }
                                .foregroundStyle(Token.Colour.accent)
                                .help("Save task")
                                .pointerStyle(.link)
                        } else if isHovering {
                            Button(action: beginEdit) { Image(systemName: "pencil") }
                                .help("Edit task")
                                .pointerStyle(.link)
                        }
                    }
                    TodoRowSlot {
                        // Hidden, not disabled, while editing: sending half-typed text to a
                        // shell is not a thing anyone means to do, and the empty slot keeps
                        // the column open for when the edit ends.
                        if !isEditing, isHovering {
                            Button(action: send) { Image(systemName: "arrow.right.to.line") }
                                .help("Send to shell")
                                .pointerStyle(.link)
                        }
                    }
                    TodoRowSlot {
                        if !isEditing, isHovering {
                            // Circled minus rather than a trash can. The can says "destroyed"; this
                            // takes one line out of a markdown file that is in the repository,
                            // which is a removal, and it is the same glyph the Context list
                            // removes a row with.
                            Button(action: delete) { Image(systemName: "minus.circle") }
                                .help("Remove task")
                                .pointerStyle(.link)
                        }
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.leading, 12 + CGFloat(item.indent) * 6)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(Token.Colour.accent)
                    .frame(height: 2)
            }
        }
        .dropDestination(for: TodoDragPayload.self) { payload, _ in
            guard let moved = payload.first?.id else { return false }
            onDropBefore(moved)
            return true
        } isTargeted: { onDragOver($0) }
    }
}

/// A section's heading, as a row.
///
/// Edited and removed the way a task is — the same pencil, the same minus, the same Return
/// and Escape, in the same slots — because it is the same kind of thing: one line of the
/// file. Two slots rather than three: there is nothing to send to a shell.
///
/// Clicking it points the composer at the section. The accent says which one is chosen, and
/// the composer's placeholder says it again in words, so colour is never the only signal.
private struct TodoHeadingRow: View {
    let heading: TodoDocument.Heading
    let isTarget: Bool
    let isDropTarget: Bool
    let isEditing: Bool
    let select: () -> Void
    let delete: () -> Void
    let beginEdit: () -> Void
    let commitEdit: (String) -> Void
    let cancelEdit: () -> Void
    let onDrop: (Int) -> Void
    let onDragOver: (Bool) -> Void
    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        // The label gives the row its height and the field is laid over it, for the reason
        // `TodoRow` gives: swapping one for the other moves every row below by a point.
        Text(heading.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isTarget ? Token.Colour.accent : Token.Colour.tertiaryLabel)
            .textCase(.uppercase)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isEditing ? 0 : 1)
            .overlay(alignment: .leading) {
                if isEditing {
                    // Not upper-cased: what is typed is what is written to the file, and a
                    // field that shouted it back would misreport that.
                    TextField("Section", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Token.Colour.label)
                        .focused($isFieldFocused)
                        .onSubmit { commitEdit(draft) }
                        .onExitCommand(perform: cancelEdit)
                        .task {
                            draft = heading.title
                            isFieldFocused = true
                        }
                }
            }
            .tileHoverControls(isHovering || isEditing) {
                HStack(spacing: 4) {
                    TodoRowSlot {
                        if isEditing {
                            Button { commitEdit(draft) } label: { Image(systemName: "return") }
                                .foregroundStyle(Token.Colour.accent)
                                .help("Save section")
                                .pointerStyle(.link)
                        } else {
                            Button(action: beginEdit) { Image(systemName: "pencil") }
                                .help("Rename section")
                                .pointerStyle(.link)
                        }
                    }
                    TodoRowSlot {
                        if !isEditing {
                            Button(action: delete) { Image(systemName: "minus.circle") }
                                .help("Remove section — its tasks stay")
                                .pointerStyle(.link)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            // Counted, so the second click of a double-click does not also toggle the
            // target the first one set.
            .onTapGesture(count: 2) { if !isEditing { beginEdit() } }
            .onTapGesture { if !isEditing { select() } }
            .help(isTarget ? "New tasks go here — click to add at the top of the list instead"
                           : "Click to add new tasks here")
            .overlay(alignment: .bottom) {
                if isDropTarget {
                    Rectangle()
                        .fill(Token.Colour.accent)
                        .frame(height: 2)
                }
            }
            .dropDestination(for: TodoDragPayload.self) { payload, _ in
                guard let moved = payload.first?.id else { return false }
                onDrop(moved)
                return true
            } isTargeted: { onDragOver($0) }
            .accessibilityLabel("Section, \(heading.title)")
            .accessibilityAddTraits(.isButton)
    }
}

/// One control's worth of a todo row, occupied or not.
///
/// A fixed width so the columns are a property of the ROW rather than of whatever happens to
/// be showing in it: hover reveals controls, editing swaps one for another, the composer's
/// Add appears with the first character typed, and none of that is allowed to move anything
/// else.
struct TodoRowSlot<Content: View>: View {
    @ViewBuilder let content: Content

    /// Wide enough for the widest glyph the slot holds (`return`), so no state of the row
    /// is the one that decides the width.
    static var width: CGFloat { 18 }

    var body: some View {
        content.frame(width: Self.width)
    }
}

/// What a dragged task carries.
///
/// A typed payload rather than a plain string: the list must not reorder itself because
/// someone dropped text from another app onto it.
struct TodoDragPayload: Codable, Transferable, Sendable {
    let id: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ultraTodoItem)
    }
}

extension UTType {
    static let ultraTodoItem = UTType(exportedAs: "com.ultra.todo-item")
}

#Preview("Todo", traits: .fixedLayout(width: 340, height: 420)) {
    TodoTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
