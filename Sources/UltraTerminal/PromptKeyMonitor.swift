import AppKit

/// Sees every key before the terminal does, and hands the two trigger characters to the
/// terminal that has the keyboard — see `ShellTerminalView.handlesPromptKey`.
///
/// A local event monitor rather than a `keyDown` override: SwiftTerm's `keyDown` is not
/// `open`, so a subclass cannot stand in front of it, and the monitor runs before the
/// window dispatches the event at all. One for the app, installed by the first shell
/// factory; it asks only the key window's first responder, and only when that is one of
/// our terminals, so every other view sees every key as before.
@MainActor
public enum PromptKeyMonitor {
    private static var token: Any?

    public static func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let terminal = event.window?.firstResponder as? ShellTerminalView,
                  terminal.handlesPromptKey(event) else { return event }
            return nil
        }
    }
}
