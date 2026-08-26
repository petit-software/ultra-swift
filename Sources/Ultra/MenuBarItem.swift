import AppKit
import Foundation
import UltraDesign

/// Ultra in the menu bar.
///
/// Earns its place by being the only surface the app has when every window is closed or
/// buried — which is exactly the situation an agent runs in. It shows the running count and
/// opens the windows again.
@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?

    /// Recreate a workspace window from the AppKit side.
    ///
    /// `openWindow` is a SwiftUI environment value, so a live window hands its own down
    /// when it starts (`WorkspaceWindow`); until one has, the standard tab action stands
    /// in, which makes a window when there is none to tab into.
    var openWorkspace: () -> Void = {
        NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
    }

    private override init() { super.init() }

    /// Create or tear down the item to match the preference, and follow it when it changes.
    func syncWithPreference() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { MenuBarItem.shared.syncWithPreference() }
                }
        }
        Preferences.showsMenuBarIcon ? show() : hide()
    }

    /// The count beside the icon, so the menu bar says the same thing as the dock badge.
    /// Blank rather than "0": a zero is a number reporting the absence of news.
    func update(runningAgents count: Int) {
        item?.button?.title = count > 0 ? " \(count)" : ""
    }

    private func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon
        item.button?.imagePosition = .imageLeading
        item.menu = buildMenu()
        self.item = item
        update(runningAgents: AgentMonitor.shared.runningCount)
    }

    private func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Ultra", action: #selector(openUltra(_:)),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ultra", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    /// Bring the app to the front and its windows back into view.
    ///
    /// The original was `NSApplication.unhide(_:)`, which reverses exactly one state: an
    /// explicit `hide(_:)`. In every other state a window can be in — visible but the app
    /// backgrounded, minimised, or closed — it is a no-op, so the item was a click that
    /// does nothing.
    @objc private func openUltra(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        var raised = false
        // Registry entries outlive their windows (a strong reference is kept), so only
        // touch windows the app still has; the rest are closed scenes to recreate.
        for window in ShellWorkspace.Registry.windows.values
            where NSApp.windows.contains(window) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            raised = true
        }
        // Every window closed: AppKit cannot bring a closed scene back, only SwiftUI can.
        if !raised { openWorkspace() }
    }

    /// The mark, as a template image.
    ///
    /// `NSImage` parses SVG directly on this platform, so the artwork lives here as text
    /// rather than as a build-time rasterisation — no resource bundle, and it stays sharp at
    /// whatever height the menu bar happens to be.
    ///
    /// `isTemplate` is what makes it follow the menu bar: the system recolours a template
    /// image for light, dark, and the inverted state while the item is open. A coloured image
    /// stays its own colour and looks wrong in at least one of those.
    static var icon: NSImage? {
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        // Sized by HEIGHT, with the width following the artwork's own ratio. The mark is
        // nearly twice as wide as it is tall, and fitting it into a square would either
        // shrink it against every other icon up there or crop it.
        let height: CGFloat = 15
        let ratio = image.size.width / max(image.size.height, 1)
        image.size = NSSize(width: (height * ratio).rounded(), height: height)
        image.isTemplate = true
        return image
    }

    private static let svg = """
    <svg width="485" height="253" viewBox="0 0 485 253" fill="none" \
    xmlns="http://www.w3.org/2000/svg">
    <path d="M127.149 0C138.767 0.000129713 147.803 7.0538 151.03 17.9551L164.896 \
    67.3606C166.627 73.5292 167.492 76.6136 169.13 79.1503C170.706 81.5908 172.794 83.6588 \
    175.25 85.2104C177.803 86.8232 180.895 87.6584 187.081 89.329L236.227 102.603C247.199 \
    105.168 254.298 114.787 254.298 125.688C254.298 137.231 247.199 146.209 236.227 \
    149.415L186.807 163.239C180.716 164.943 177.67 165.795 175.155 167.404C172.735 168.952 \
    170.677 171.003 169.121 173.417C167.504 175.927 166.642 178.97 164.917 185.056L151.03 \
    234.062C147.803 244.964 138.767 252.017 127.149 252.018C115.532 252.018 106.496 244.964 \
    103.269 234.062L89.4024 184.657C87.6711 178.488 86.8055 175.404 85.1677 172.867C83.5921 \
    170.427 81.5038 168.359 79.048 166.807C76.4953 165.194 73.4027 164.359 67.2175 \
    162.689L18.0723 149.415C7.74554 146.209 0.645548 137.231 0 125.688C0 114.787 7.10001 \
    105.809 18.0723 102.603L67.8923 88.7999C74.067 87.0892 77.1544 86.2339 79.6967 \
    84.6044C82.1425 83.0368 84.2175 80.9552 85.7773 78.5044C87.3986 75.9569 88.2441 72.8668 \
    89.935 66.6866L103.269 17.9551C106.496 7.05379 115.532 0 127.149 0Z" fill="white"/>
    <path d="M484.297 188.009C484.297 210.411 484.297 221.612 479.937 230.168C476.102 \
    237.695 469.983 243.814 462.456 247.649C453.9 252.009 442.699 252.009 420.297 \
    252.009H379.297C356.895 252.009 345.694 252.009 337.137 247.649C329.611 243.814 323.492 \
    237.695 319.657 230.168C315.297 221.612 315.297 210.411 315.297 188.009V64.0088C315.297 \
    41.6067 315.297 30.4056 319.657 21.8492C323.492 14.3227 329.611 8.20346 337.137 \
    4.36853C345.694 0.00878906 356.895 0.00878906 379.297 0.00878906H420.297C442.699 \
    0.00878906 453.9 0.00878906 462.456 4.36853C469.983 8.20346 476.102 14.3227 479.937 \
    21.8492C484.297 30.4056 484.297 41.6067 484.297 64.0088V188.009Z" fill="white"/>
    </svg>
    """
}
