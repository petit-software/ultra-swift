import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UltraDesign

/// The project's todo list, as a file.
public struct TodoTile: View {
    @State private var store: TodoStore
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool
    /// The row a drag is currently over, so the insertion line follows the pointer.
    @State private var dropTarget: Int?
    /// The task being edited, if any.
    ///
    /// Held HERE rather than in the row, so that opening one editor closes the last. Two
    /// rows in edit mode at once is two drafts of a list that has one file behind it.
    @State private var editingID: Int?
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
        if store.document.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 22))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                // The path used to be repeated here. The footer carries it now, on every
                // state of the tile rather than only the empty one.
                Text(store.exists ? "No tasks yet" : "No list in this project yet")
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(Token.Colour.secondaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.document.grouped) { group in
                        // A heading earns its space only when there is something to tell
                        // apart. One section means the title names the whole list, which
                        // the pane header already does — so it is just a word in the way.
                        if let section = group.section, showsSectionHeadings {
                            Text(section)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Token.Colour.tertiaryLabel)
                                .textCase(.uppercase)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
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

    /// Headings are shown only once there are several. See the comment at the call site.
    private var showsSectionHeadings: Bool {
        store.document.grouped.count > 1
    }

    /// The add field, sitting at the head of the list and shaped like a row in it.
    ///
    /// At the top rather than the bottom because that is where the new task lands, and a
    /// composer that writes to the opposite end of the list from where it sits makes you
    /// hunt for what you just typed. Its circle is the same circle a task wears, in the same
    /// column, so the field reads as the row about to exist rather than a bar bolted on.
    private var composer: some View {
        // Centred rather than baseline-aligned. A task row aligns to the first text baseline
        // because its label can wrap to several lines and the checkbox belongs beside the
        // first of them; the field here is always one line, so the baseline just pushes the
        // glyph low against a row it is supposed to sit in the middle of.
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                // Sized to the circle it replaced so the field's text still starts on the
                // same column as every task's label below it.
                .frame(width: 14)
                .foregroundStyle(draftFocused ? Token.Colour.accent : Token.Colour.tertiaryLabel)

            TextField("Add a task", text: $draft)
                .textFieldStyle(.plain)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.label)
                .focused($draftFocused)
                .onSubmit(add)

            // The slot is always here; only the glyph inside it comes and goes. Appearing
            // and disappearing, the button changed the composer's height as well as its
            // width, so the first character typed nudged the whole list below it — and the
            // moment the task landed and the draft emptied, nudged it back.
            TodoRowSlot {
                Button(action: add) { Image(systemName: "return") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.accent)
                    .help("Add task")
                    .opacity(draft.isEmpty ? 0 : 1)
                    .disabled(draft.isEmpty)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .contentShape(.rect)
        // Clicking anywhere along the row starts typing, the way clicking a task row hits
        // its whole width rather than just the words.
        .onTapGesture { draftFocused = true }
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

    private func add() {
        store.prependItem(draft)
        draft = ""
        // Focus is kept so several tasks can be typed in a row without reaching for the
        // mouse between them.
        draftFocused = true
    }

    /// Write an edited task back, and leave edit mode either way.
    ///
    /// An empty result REVERTS rather than deleting. Deleting is a separate verb with its own
    /// button, and clearing a field is far more often a slip on the way to retyping than it
    /// is a decision to throw the task away — one that a list backed by a file in the repo
    /// has no undo for.
    private func commitEdit(_ text: String, for item: TodoDocument.Item) {
        editingID = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.text else { return }
        store.setText(trimmed, for: item.id)
    }

    private func noticeBar(_ notice: TodoStore.Notice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: notice == .reloadedFromDisk
                  ? "arrow.clockwise" : "exclamationmark.triangle")
            Text(message(for: notice))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Token.Colour.accentWash)
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
                    .foregroundStyle(item.isDone ? Token.Colour.accent : Token.Colour.tertiaryLabel)
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

            // Three slots, always the same three columns, whatever is in them. The row used
            // to carry three controls on hover and a single one while editing, so pressing
            // the pencil re-flowed the cluster and every icon landed somewhere else —
            // including under the pointer that had just pressed one.
            //
            // The cluster appears with the hover and stays for the edit, rather than sitting
            // there empty on every row: a todo pane is narrow, and 62pt held open on the
            // right of a resting list wraps task text for controls nobody is reaching for.
            if isHovering || isEditing {
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
                            // Minus rather than a trash can. The can says "destroyed"; this
                            // takes one line out of a markdown file that is in the repository,
                            // which is a removal, and it is the same glyph the Context list
                            // removes a row with.
                            Button(action: delete) { Image(systemName: "minus") }
                                .help("Remove task")
                                .pointerStyle(.link)
                        }
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

/// One control's worth of a todo row, occupied or not.
///
/// A fixed width so the columns are a property of the ROW rather than of whatever happens to
/// be showing in it: hover reveals controls, editing swaps one for another, the composer's
/// Add appears with the first character typed, and none of that is allowed to move anything
/// else.
private struct TodoRowSlot<Content: View>: View {
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
