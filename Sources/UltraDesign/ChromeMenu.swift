import AppKit
import SwiftUI

/// One row in a chrome menu.
public enum ChromeMenuEntry {
    /// A non-pressable line of context, such as where a file lives.
    case caption(String)
    case separator
    case item(title: String, symbol: String? = nil, isOn: Bool = false,
              isEnabled: Bool = true, action: () -> Void)
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
        let rows = entries()
        // An empty NSMenu declines to open, which reads as a dead button rather than an
        // empty list. Callers hide the control instead.
        guard !rows.isEmpty, let anchorView = anchor.view else { return }

        let menu = ChromeMenu()
        let handler = ChromeMenuTarget(rows: rows)
        menu.handler = handler
        // AppKit re-derives every item's enabled state from its target unless told not to,
        // which would undo both the captions and any deliberately greyed row.
        menu.autoenablesItems = false

        for (index, row) in rows.enumerated() {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .caption(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case let .item(title, symbol, isOn, isEnabled, _):
                let item = NSMenuItem(title: title,
                                      action: #selector(ChromeMenuTarget.pick(_:)),
                                      keyEquivalent: "")
                item.target = handler
                item.tag = index
                item.isEnabled = isEnabled
                item.state = isOn ? .on : .off
                if let symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu.addItem(item)
            }
        }

        // Dropped from the control's bottom edge rather than the pointer, so the menu is
        // anchored to the thing the user aimed at. Hosting views are flipped; this does not
        // assume it.
        let y = anchorView.isFlipped ? anchorView.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchorView)
    }
}

/// Holds the closures the menu items call.
///
/// `NSMenuItem.target` is a WEAK reference. Without something owning this for the lifetime of
/// the menu, the handler is deallocated before the click lands and every item silently does
/// nothing — the menu opens, you pick a row, and nothing happens.
@MainActor
private final class ChromeMenuTarget: NSObject {
    private let rows: [ChromeMenuEntry]
    init(rows: [ChromeMenuEntry]) { self.rows = rows }

    @objc func pick(_ sender: NSMenuItem) {
        guard rows.indices.contains(sender.tag),
              case let .item(_, _, _, _, action) = rows[sender.tag] else { return }
        action()
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
