import Foundation

/// One option of the Settings window, as its search finds it: the control's own label,
/// the section it sits in, the pane that section is on, and the other words someone
/// might type for it.
///
/// A TABLE, kept beside the panes rather than read out of them: a SwiftUI form cannot be
/// asked what controls it holds. An option added to a pane is added here, with the label
/// it has there — the search can only find what is listed.
struct SettingsOption: Identifiable, Equatable {
    let pane: SettingsPane
    let section: String
    let title: String
    var keywords: [String] = []

    var id: String { "\(pane.rawValue)/\(section)/\(title)" }

    /// Where it is, as the result's second line says it: "Terminal ▸ Text".
    var path: String { "\(pane.title) ▸ \(section)" }
}

@MainActor
enum SettingsSearch {
    /// Every option, in the order the panes list them.
    static let options: [SettingsOption] = [
        .init(pane: .general, section: "Startup", title: "New windows open in",
              keywords: ["start folder", "default project", "launch"]),
        .init(pane: .general, section: "Updates", title: "Check for updates automatically",
              keywords: ["update", "version", "sparkle", "check now"]),
        .init(pane: .general, section: "Menu bar", title: "Show Ultra in the menu bar",
              keywords: ["status item", "menu bar icon"]),
        .init(pane: .general, section: "Layout", title: "Default layout",
              keywords: ["arrangement", "panes", "clear"]),
        .init(pane: .general, section: "Reset", title: "Reset All Settings",
              keywords: ["defaults", "restore", "factory"]),

        .init(pane: .appearance, section: "Appearance", title: "Appearance",
              keywords: ["theme", "dark mode", "light mode", "follow system", "colour mode",
                         "color mode"]),
        .init(pane: .appearance, section: "Aurora", title: "Aurora",
              keywords: ["glow", "project colour", "project color"]),
        .init(pane: .appearance, section: "Aurora", title: "Strength",
              keywords: ["aurora strength", "glow"]),
        .init(pane: .appearance, section: "Light mode", title: "Focused pane",
              keywords: ["white", "paper", "tint"]),
        .init(pane: .appearance, section: "Light mode", title: "Other panes",
              keywords: ["unfocused", "white", "tint"]),
        .init(pane: .appearance, section: "Light mode", title: "Window frame",
              keywords: ["white", "tint"]),
        .init(pane: .appearance, section: "Light mode", title: "Reset Light Mode",
              keywords: ["copy values"]),

        .init(pane: .terminal, section: "Accent", title: "Accent",
              keywords: ["colour", "color", "highlight", "tint"]),
        .init(pane: .terminal, section: "Text", title: "Font size",
              keywords: ["text size", "point", "bigger", "smaller"]),
        .init(pane: .terminal, section: "Bell", title: "Audible bell",
              keywords: ["sound", "beep"]),
        .init(pane: .terminal, section: "Agent prompts", title: "Prompt menus for @ and /",
              keywords: ["mention", "slash command", "completion", "file picker"]),
        .init(pane: .terminal, section: "Links", title: "⌘-click on a link",
              keywords: ["command click", "url", "browser", "open link"]),
        .init(pane: .terminal, section: "Rendering", title: "Draw terminals on the GPU",
              keywords: ["metal", "performance", "renderer"]),

        .init(pane: .tiles, section: "File tree", title: "Show dotfiles",
              keywords: ["hidden files"]),
        .init(pane: .tiles, section: "Editor", title: "Open Markdown as a page",
              keywords: ["reading mode", "preview", "md"]),
        .init(pane: .tiles, section: "Project files", title: "Todo file",
              keywords: ["todo.md", "plan", "task list"]),
        .init(pane: .tiles, section: "Project files", title: "Context file",
              keywords: ["context.json", "bookmarks"]),
        .init(pane: .tiles, section: "Agents", title: "Write AGENTS.md into new projects",
              keywords: ["claude.md", "instructions"]),
        .init(pane: .tiles, section: "Refresh every", title: "Ports",
              keywords: ["interval", "seconds", "polling", "lsof"]),
        .init(pane: .tiles, section: "Refresh every", title: "Resources",
              keywords: ["interval", "seconds", "polling", "cpu", "memory"]),
        .init(pane: .tiles, section: "Refresh every", title: "Git",
              keywords: ["interval", "seconds", "polling"]),
        .init(pane: .tiles, section: "Refresh every", title: "Pause while the window is hidden",
              keywords: ["battery", "polling", "background"]),

        .init(pane: .agents, section: "Sleep", title: "Keep this Mac awake while an agent is running",
              keywords: ["caffeinate", "prevent sleep", "lid"]),
        .init(pane: .agents, section: "Notifications",
              title: "Notify me when an agent finishes or waits for me",
              keywords: ["notification", "alert", "done", "banner"]),
        .init(pane: .agents, section: "Notifications", title: "When one waits, show",
              keywords: ["answer window", "floating", "picture in picture", "approve", "reply"]),

        .init(pane: .chat, section: "Default", title: "New chats use",
              keywords: ["provider", "model", "service"]),
        .init(pane: .chat, section: "Subscriptions", title: "Claude Code",
              keywords: ["claude", "sign in", "plan", "subscription"]),
        .init(pane: .chat, section: "Subscriptions", title: "Codex",
              keywords: ["chatgpt", "openai", "sign in", "plan", "subscription"]),
        .init(pane: .chat, section: "API keys", title: "Anthropic",
              keywords: ["api key", "claude", "keychain"]),
        .init(pane: .chat, section: "API keys", title: "OpenRouter",
              keywords: ["api key", "openai", "google", "keychain"]),

        .init(pane: .tuning, section: "Frosted panes", title: "Glass panes",
              keywords: ["liquid glass", "frost", "material", "blur"]),
        .init(pane: .tuning, section: "Glass panes", title: "Style",
              keywords: ["glass", "tint"]),
        .init(pane: .tuning, section: "Pane shape", title: "Pane shape",
              keywords: ["corner", "radius", "gutter", "shadow", "padding"]),
        .init(pane: .tuning, section: "Pane header", title: "Pane header",
              keywords: ["height", "title"]),
        .init(pane: .tuning, section: "Window", title: "Material",
              keywords: ["window", "tint", "edge", "reset look"]),

        .init(pane: .about, section: "About", title: "Version",
              keywords: ["about", "build", "ultra", "swiftterm"]),
    ]

    /// The options a query finds, among the panes on show: every word typed has to be in
    /// the option's label, its section, its pane's name or one of its keywords. Those
    /// that match in the label itself come first, then in the order of the panes.
    static func results(for query: String, panes: [SettingsPane] = SettingsPane.shown) -> [SettingsOption] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let found = options.filter { option in
            guard panes.contains(option.pane) else { return false }
            let haystack = ([option.title, option.section, option.pane.title] + option.keywords)
                .joined(separator: "\n").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let inTitle = { (option: SettingsOption) in
            words.allSatisfy { option.title.lowercased().contains($0) }
        }
        return found.filter(inTitle) + found.filter { !inTitle($0) }
    }
}
