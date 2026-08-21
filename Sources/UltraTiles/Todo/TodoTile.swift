import AppKit
import SwiftUI
import UltraDesign

/// The project's todo list, as a file.
public struct TodoTile: View {
    @State private var store: TodoStore
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool
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
                    ForEach(groupedItems, id: \.0) { section, items in
                        if let section {
                            Text(section)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Token.Colour.tertiaryLabel)
                                .textCase(.uppercase)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
                        }
                        ForEach(items) { item in
                            TodoRow(item: item,
                                    toggle: { store.toggle(item.id) },
                                    send: { context.injectIntoShell(item.text) },
                                    delete: { store.removeItem(item.id) })
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    /// Items grouped by their heading, in file order.
    private var groupedItems: [(String?, [TodoDocument.Item])] {
        var out: [(String?, [TodoDocument.Item])] = []
        for item in store.document.items {
            if out.last?.0 == item.section {
                out[out.count - 1].1.append(item)
            } else {
                out.append((item.section, [item]))
            }
        }
        return out
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
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
    let toggle: () -> Void
    let send: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button(action: toggle) {
                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? Token.Colour.accent : Token.Colour.tertiaryLabel)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(item.isDone ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .strikethrough(item.isDone, color: Token.Colour.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if isHovering {
                Button(action: send) { Image(systemName: "arrow.right.to.line") }
                    .help("Send to shell")
                Button(action: delete) { Image(systemName: "trash") }
                    .help("Delete task")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.leading, 12 + CGFloat(item.indent) * 6)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

#Preview("Todo", traits: .fixedLayout(width: 340, height: 420)) {
    TodoTile(context: .inert(root: URL(fileURLWithPath: NSHomeDirectory())))
}
