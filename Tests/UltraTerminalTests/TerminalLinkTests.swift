import AppKit
import Testing
@testable import UltraTerminal

@Suite("Links clicked in a terminal")
struct TerminalLinkTests {
    private let page = URL(string: "http://localhost:3000/docs")!

    @Test("a web link opens in the browser pane when the setting is on")
    func webLinkGoesToThePane() {
        #expect(ShellTerminalView.linkOpensInPane(page, modifiers: [.command], preferred: true))
        #expect(ShellTerminalView.linkOpensInPane(URL(string: "https://swift.org")!, modifiers: [.command], preferred: true))
    }

    @Test("⌥⌘-click, the setting off, or a file link go to the system")
    func escapes() {
        #expect(!ShellTerminalView.linkOpensInPane(page, modifiers: [.command, .option], preferred: true))
        #expect(!ShellTerminalView.linkOpensInPane(page, modifiers: [.command], preferred: false))
        #expect(!ShellTerminalView.linkOpensInPane(URL(string: "file:///tmp/a.txt")!, modifiers: [.command], preferred: true))
    }
}
