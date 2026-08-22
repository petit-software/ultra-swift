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
    private let context: TileContext

    public init(context: TileContext) {
        self.context = context
        _store = State(initialValue: TodoStore(root: context.root))
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = store.notice { noticeBar(notice) }
            list
            composer
        }
        .background(Token.Colour.paneBackground)
        .tileHeaderInset()
    }

    @ViewBuilder
    private var list: some View {
        if store.document.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 22))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                Text(store.exists ? "No tasks yet" : "No list in this project yet")
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(Token.Colour.secondaryLabel)
                Text(TileFactory.abbreviate(store.url.path))
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.document.grouped) { group in
                        if let section = group.section {
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
                                    toggle: { store.toggle(item.id) },
                                    send: { context.injectIntoShell(item.text) },
                                    delete: { store.removeItem(item.id) },
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
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            TextField("Add a task", text: $draft)
                .textFieldStyle(.plain)
                .font(Token.Type_.tileSubtitle)
                .focused($draftFocused)
                .onSubmit(add)
            if !draft.isEmpty {
                Button(action: add) { Image(systemName: "return") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.accent)
            }

            Menu {
                Text(TileFactory.abbreviate(store.url.path))
                Divider()
                Button("Choose Location…") { chooseLocation() }
                Button("Use Project Default") { store.resetLocation() }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Token.Colour.tertiaryLabel)
            .help("Where this list is stored")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
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
        store.addItem(draft, to: store.document.sections.last)
        draft = ""
        draftFocused = true
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
        .background(Token.Colour.accent.opacity(0.12))
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
    let toggle: () -> Void
    let send: () -> Void
    let delete: () -> Void
    let onDropBefore: (Int) -> Void
    let onDragOver: (Bool) -> Void
    @State private var isHovering = false

    @State private var dropTarget: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button(action: toggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? Token.Colour.accent : Token.Colour.tertiaryLabel)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Text(item.text)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(item.isDone ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .strikethrough(item.isDone, color: Token.Colour.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if isHovering {
                Button(action: send) { Image(systemName: "arrow.right.to.line") }
                    .help("Send to shell")
                    .pointerStyle(.link)
                Button(action: delete) { Image(systemName: "trash") }
                    .help("Delete task")
                    .pointerStyle(.link)
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
        // The whole row is the handle. A todo list is short and the rows are small; a
        // separate grip would be a smaller target for no gain.
        .draggable(TodoDragPayload(id: item.id)) {
            Text(item.text)
                .font(Token.Type_.tileSubtitle)
                .padding(6)
                .background(Token.Colour.tileBackground)
        }
        .dropDestination(for: TodoDragPayload.self) { payload, _ in
            guard let moved = payload.first?.id else { return false }
            onDropBefore(moved)
            return true
        } isTargeted: { onDragOver($0) }
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
