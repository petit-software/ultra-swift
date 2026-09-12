import AppKit
import SwiftUI

/// One row in a chrome menu.
public enum ChromeMenuEntry {
    /// A non-pressable line of context, such as where a file lives.
    case caption(String)
    case separator
    case item(title: String, symbol: String? = nil, isOn: Bool = false,
              isEnabled: Bool = true, action: () -> Void)
    /// A row that opens another menu, for a list too long to be one: a vendor's models, say.
    /// Ticked when one of its rows is, so the choice shows without opening it.
    case submenu(title: String, entries: [ChromeMenuEntry])
}

/// A `ChromeIconButton` that opens a menu.
///
/// Deliberately an `NSMenu` popped by hand rather than SwiftUI's `Menu`. Two reasons, both
/// paid for:
///
/// - A `Menu` in a pane header renders perfectly and never opens. The header is an
///   `NSHostingView` floating over the pane's content, and the tap never reaches it.
/// - `.menuStyle(.borderlessButton)` draws its own chrome and `.fixedSize()` collapses the
///   label's frame, so a `Menu` in a footer came out a different size with a different hover
///   from the buttons beside it — however carefully its label was built.
///
/// Going through AppKit is what makes a menu control the same object as a plain one.
public struct ChromeMenuButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = ChromeIconLabel.size
    var tint: Color?
    let entries: () -> [ChromeMenuEntry]

    @State private var anchor = MenuAnchorBox()

    public init(symbol: String, help: String, size: CGFloat = ChromeIconLabel.size,
                tint: Color? = nil,
                entries: @escaping () -> [ChromeMenuEntry]) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.tint = tint
        self.entries = entries
    }

    public var body: some View {
        ChromeIconButton(symbol: symbol, help: help, size: size, tint: tint, action: present)
            .background(MenuAnchorView(box: anchor))
    }

    private func present() {
        guard let anchorView = anchor.view else { return }
        ChromeMenuPresenter.popUp(entries(), from: anchorView)
    }
}

/// A chrome menu hanging off an arbitrary label rather than a lone glyph.
///
/// The pane header's identity — icon and name together — is one of these: the whole thing
/// is what you press to change what the pane is, so the whole thing takes the click and the
/// whole thing wears the hover plate. The label is handed the hover state so it can answer
/// it the way `ChromeIconLabel` does.
public struct ChromeMenuTrigger<Label: View>: View {
    let help: String
    let entries: () -> [ChromeMenuEntry]
    let label: (_ isHovering: Bool) -> Label

    @State private var anchor = MenuAnchorBox()
    @State private var isHovering = false

    public init(help: String,
                entries: @escaping () -> [ChromeMenuEntry],
                @ViewBuilder label: @escaping (_ isHovering: Bool) -> Label) {
        self.help = help
        self.entries = entries
        self.label = label
    }

    public var body: some View {
        Button(action: present) { label(isHovering) }
            .buttonStyle(.plain)
            .background(MenuAnchorView(box: anchor))
            .onHover { isHovering = $0 }
            .help(help)
            .accessibilityLabel(help)
    }

    private func present() {
        guard let anchorView = anchor.view else { return }
        ChromeMenuPresenter.popUp(entries(), from: anchorView)
    }
}

/// Builds and pops the `NSMenu` behind every chrome menu control, so an icon button and a
/// labelled trigger cannot open two differently-built menus.
public enum ChromeMenuPresenter {
    @MainActor
    public static func popUp(_ rows: [ChromeMenuEntry], from anchorView: NSView) {
        // An empty NSMenu declines to open, which reads as a dead button rather than an
        // empty list. Callers hide the control instead.
        guard !rows.isEmpty else { return }

        let menu = ChromeMenu()
        let handler = ChromeMenuTarget()
        menu.handler = handler
        fill(menu, with: rows, handler: handler)

        // Dropped from the control's bottom edge rather than the pointer, so the menu is
        // anchored to the thing the user aimed at. Hosting views are flipped; this does not
        // assume it.
        let y = anchorView.isFlipped ? anchorView.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchorView)
    }

    /// The rows, as items of `menu`; a submenu row recurses. Returns whether any row in the
    /// menu, or in one below it, is ticked, so the submenu's own row can be.
    @MainActor
    @discardableResult
    static func fill(_ menu: NSMenu, with rows: [ChromeMenuEntry], handler: ChromeMenuTarget) -> Bool {
        // AppKit re-derives every item's enabled state from its target unless told not to,
        // which would undo both the captions and any deliberately greyed row.
        menu.autoenablesItems = false
        var anyOn = false
        for row in rows {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .caption(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case let .item(title, symbol, isOn, isEnabled, action):
                let item = NSMenuItem(title: title,
                                      action: #selector(ChromeMenuTarget.pick(_:)),
                                      keyEquivalent: "")
                item.target = handler
                item.tag = handler.register(action)
                item.isEnabled = isEnabled
                item.state = isOn ? .on : .off
                if let symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu.addItem(item)
                anyOn = anyOn || isOn
            case let .submenu(title, entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: title)
                let isOn = fill(sub, with: entries, handler: handler)
                item.submenu = sub
                item.state = isOn ? .on : .off
                item.isEnabled = !entries.isEmpty
                menu.addItem(item)
                anyOn = anyOn || isOn
            }
        }
        return anyOn
    }
}

/// Holds the closures the menu items call, one per item, found again by the item's tag.
///
/// `NSMenuItem.target` is a WEAK reference. Without something owning this for the lifetime of
/// the menu, the handler is deallocated before the click lands and every item silently does
/// nothing — the menu opens, you pick a row, and nothing happens.
@MainActor
final class ChromeMenuTarget: NSObject {
    private var actions: [() -> Void] = []

    func register(_ action: @escaping () -> Void) -> Int {
        actions.append(action)
        return actions.count - 1
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// An `NSMenu` that keeps its target alive for as long as it is on screen.
private final class ChromeMenu: NSMenu {
    var handler: AnyObject?
}

/// Captures the AppKit view behind a control, so a menu has something to hang from.
@MainActor
public final class MenuAnchorBox {
    weak var view: NSView?
    public init() {}
}

struct MenuAnchorView: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

#Preview("Chrome menu trigger — labelled", traits: .fixedLayout(width: 260, height: 60)) {
    ChromeMenuTrigger(help: "Change Pane Type",
                      entries: { [.item(title: "Shell", symbol: "apple.terminal") {},
                                  .item(title: "Editor", symbol: "doc.text", isOn: true, isEnabled: false) {},
                                  .submenu(title: "anthropic", entries: [.item(title: "claude-opus-5", isOn: true) {}])] }) { hovering in
        HStack(spacing: 0) {
            ChromeIconLabel(symbol: "apple.terminal", isHovering: hovering)
            Text("Shell").padding(.trailing, 8)
        }
    }
    .padding()
}
