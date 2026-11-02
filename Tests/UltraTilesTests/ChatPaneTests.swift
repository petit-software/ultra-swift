import Foundation
import Testing
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTiles

/// A chat pane's look: pinned light the way a browser pane's page mode is, saved with the
/// pane and restored with it. Not the conversation — the store's own tests cover that.
@Suite("Chat pane")
@MainActor
struct ChatPaneTests {

    private func scratchRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-chat-pane-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a chat shown light is the pane's appearance; one that follows the app pins nothing")
    func lightRecord() {
        let root = scratchRoot()
        let store = ChatStore(root: root)
        let light = TileFactory.chatRecord(for: store.current, appearance: .light, root: root)
        let plain = TileFactory.chatRecord(for: store.current, root: root)
        #expect(light.appearance == .light)
        #expect(plain.appearance == nil)
        #expect(light.kind == .chat)
    }

    @Test("a restored light pane comes back light")
    func restoreLight() {
        let root = scratchRoot()
        let paneID = PaneID()
        let saved = TileFactory.chatRecord(for: ChatStore(root: root).current, appearance: .light, root: root)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        _ = factory.makeContent(for: paneID)
        #expect(factory.chatStore(for: paneID)?.pinnedAppearance == .light)
    }

    @Test("the switch pins the other look from the app's, saved on the record, and back again clears it")
    func toggleUpdatesRecord() {
        let root = scratchRoot()
        let paneID = PaneID()
        let saved = TileFactory.chatRecord(for: ChatStore(root: root).current, root: root)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        var changed: PaneRecord?
        factory.onRecordChange = { _, record in changed = record }
        _ = factory.makeContent(for: paneID)
        let store = try? #require(factory.chatStore(for: paneID))
        store?.toggleAppearance(appIsDark: true)
        #expect(changed?.appearance == .light)
        store?.toggleAppearance(appIsDark: true)
        #expect(changed?.appearance == nil)
        // In a light app the switch is the dark look, not a light pin that changes nothing.
        store?.toggleAppearance(appIsDark: false)
        #expect(changed?.appearance == .dark)
        #expect(changed?.kind == .chat)
    }
}

/// A link in an answer, as Foundation's Markdown parser hands it over — the form a model
/// writes when it links a file it made.
@Suite("Chat links")
struct ChatLinkTests {

    private func link(_ markdown: String) -> URL {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let text = try! AttributedString(markdown: markdown, options: options)
        return text.runs.compactMap(\.link).first!
    }

    private func project() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-chat-links-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("Tailor feedback.md").path,
                                       contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("Sources/a.swift").path,
                                       contents: Data())
        return root.standardizedFileURL
    }

    @Test("an absolute path with a space, in angle brackets, is the file")
    func absolutePath() {
        let root = project()
        let file = root.appendingPathComponent("Tailor feedback.md")
        let url = link("[Tailor feedback.md](<\(file.path)>)")
        #expect(ChatLink.file(for: url, root: root)?.path == file.path)
    }

    @Test("a path relative to the project, with or without a line, is the file")
    func relativePath() {
        let root = project()
        let file = root.appendingPathComponent("Sources/a.swift").path
        for markdown in ["[a](Sources/a.swift)", "[a](Sources/a.swift:12)",
                         "[a](Sources/a.swift:12:4)", "[a](Sources/a.swift#L12)"] {
            #expect(ChatLink.file(for: link(markdown), root: root)?.path == file, "\(markdown)")
        }
    }

    @Test("a file URL is the file; a folder comes back as a folder")
    func fileURLAndFolder() {
        let root = project()
        let file = root.appendingPathComponent("Tailor feedback.md")
        #expect(ChatLink.file(for: file, root: root)?.path == file.path)
        #expect(ChatLink.file(for: link("[s](Sources)"), root: root)?.hasDirectoryPath == true)
    }

    @Test("a path that names nothing is nothing, and a web link is not a path")
    func missingAndWeb() {
        let root = project()
        let missing = link("[x](Sources/missing.swift)")
        #expect(ChatLink.file(for: missing, root: root) == nil)
        #expect(ChatLink.isPath(missing))
        let web = link("[x](https://example.com/a.swift)")
        #expect(ChatLink.file(for: web, root: root) == nil)
        #expect(!ChatLink.isPath(web))
    }
}

/// The editor's and the chat's sun and moon: the other look from the app's, in both.
@Suite("Pane look switch")
@MainActor
struct PaneLookTests {

    @Test("pinning goes to the look the app is not wearing, and switching again follows it")
    func toggled() {
        #expect(PaneLook.toggled(nil, appIsDark: true) == .light)
        #expect(PaneLook.toggled(nil, appIsDark: false) == .dark)
        #expect(PaneLook.toggled(.light, appIsDark: true) == nil)
        #expect(PaneLook.toggled(.dark, appIsDark: false) == nil)
    }

    @Test("the symbol is the look a click leads to, and the tooltip says which")
    func button() {
        #expect(PaneLook.symbol(nil, appIsDark: true) == "sun.max")
        #expect(PaneLook.symbol(nil, appIsDark: false) == "moon")
        #expect(PaneLook.symbol(.light, appIsDark: true) == "moon")
        #expect(PaneLook.symbol(.dark, appIsDark: false) == "sun.max")
        #expect(PaneLook.help(nil, appIsDark: false, pane: "Editor") == "Show Editor Dark (⌃⌘L)")
        #expect(PaneLook.help(.dark, appIsDark: false, pane: "Editor").hasPrefix("Follow"))
    }

    @Test("an editor pinned dark in a light app is saved dark and restored dark")
    func editorRestoresDark() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let paneID = PaneID()
        var saved = TileFactory.record(for: .editor, root: root)
        saved.appearance = .dark
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        let content = factory.makeContent(for: paneID)
        #expect(content?.record.appearance == .dark)
    }
}
