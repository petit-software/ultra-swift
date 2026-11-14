import AppKit
import UltraDesign

/// What a ⌘-click in a terminal landed on, once it is known to be something that opens.
public enum LinkTarget: Equatable, Sendable {
    /// An `http` or `https` page.
    case web(URL)
    /// A file that exists: a path the shell or an agent printed, or a `file:` link.
    case file(URL)
    /// A folder that exists. Not a package — an `.app` is a `file`, so it is shown rather
    /// than launched.
    case folder(URL)

    public var url: URL {
        switch self {
        case .web(let url), .file(let url), .folder(let url): url
        }
    }

    public var isWeb: Bool {
        if case .web = self { return true }
        return false
    }
}

/// One thing that can be done with a clicked link: a row of the link menu, or what a
/// click does straight away when the setting says not to ask.
public enum LinkAction: Equatable, Sendable {
    /// A page in the browser pane, a file in the editor pane.
    case openInUltra
    /// The default browser.
    case openInBrowser
    /// A folder opened in Finder, a file selected in its folder.
    case showInFinder
    /// The file's own app, as a double click in Finder would.
    case openWithDefaultApp
    case copy
}

/// The menu a ⌘-click on a link shows, and the rule for when it shows.
///
/// Pure, so the rows and the rule are tested without a window; `ShellTerminalView` pops
/// the menu and carries out the pick.
public enum TerminalLinkMenu {

    /// What a click does on its own, or nil to ask with the menu.
    ///
    /// ⌥⌘-click never asks: it is the way out to the Mac — the real browser with its
    /// logins, the file's own app — whatever the setting says.
    public static func clickAction(for target: LinkTarget, modifiers: NSEvent.ModifierFlags,
                                   preference: Preferences.LinkClick) -> LinkAction? {
        if modifiers.contains(.option) {
            switch target {
            case .web: return .openInBrowser
            case .file: return .openWithDefaultApp
            case .folder: return .showInFinder
            }
        }
        switch preference {
        case .ask:
            return nil
        case .ultra:
            // No pane shows a folder; Finder is the only place it opens.
            if case .folder = target { return .showInFinder }
            return .openInUltra
        case .system:
            return target.isWeb ? .openInBrowser : .showInFinder
        }
    }

    /// Where an Ultra open that could not happen goes instead — a canvas with no browser
    /// or editor and no room for one. A click on a link always opens something.
    public static func fallback(for target: LinkTarget) -> LinkAction {
        target.isWeb ? .openInBrowser : .showInFinder
    }

    /// The menu's rows, in order; nil is a separator.
    public static func actions(for target: LinkTarget) -> [LinkAction?] {
        switch target {
        case .web: [.openInUltra, .openInBrowser, nil, .copy]
        case .file: [.openInUltra, .showInFinder, .openWithDefaultApp, nil, .copy]
        case .folder: [.showInFinder, nil, .copy]
        }
    }

    /// A row's title. `defaultApp` names the app a file opens with, when it has one.
    public static func title(of action: LinkAction, for target: LinkTarget,
                             defaultApp: String? = nil) -> String {
        switch action {
        case .openInUltra: "Open in Ultra"
        case .openInBrowser: "Open in Browser"
        case .showInFinder:
            if case .folder = target { "Open in Finder" } else { "Show in Finder" }
        case .openWithDefaultApp: defaultApp.map { "Open with \($0)" } ?? "Open with Default App"
        case .copy: target.isWeb ? "Copy Link" : "Copy Path"
        }
    }

    public static func symbol(of action: LinkAction) -> String {
        switch action {
        case .openInUltra: "macwindow"
        case .openInBrowser: "safari"
        case .showInFinder: "folder"
        case .openWithDefaultApp: "arrow.up.forward.app"
        case .copy: "doc.on.doc"
        }
    }

    /// The name of the app a file opens with, without its `.app`.
    @MainActor
    static func defaultAppName(for file: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: file) else { return nil }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
