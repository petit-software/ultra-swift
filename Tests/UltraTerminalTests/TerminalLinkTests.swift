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

@Suite("File paths clicked in a terminal")
struct TerminalFileLinkTests {
    private let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ultra-file-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir.appending(path: "Sources/My Dir"),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appending(path: "Sources/a.swift").path, contents: Data())
        return dir.standardizedFileURL
    }()

    @Test("an absolute path, a file: URL, and a relative path against the shell's directory")
    func resolves() {
        let file = root.appending(path: "Sources/a.swift")
        #expect(ShellTerminalView.fileLink(file.path, cwd: nil) == file)
        #expect(ShellTerminalView.fileLink(file.absoluteString, cwd: nil) == file)
        #expect(ShellTerminalView.fileLink("Sources/a.swift", cwd: root.path) == file)
        #expect(ShellTerminalView.fileLink("./Sources/a.swift", cwd: root.path) == file)
        #expect(ShellTerminalView.fileLink("../Sources/a.swift", cwd: root.appending(path: "Sources").path) == file)
        #expect(ShellTerminalView.fileLink("Sources/My Dir", cwd: root.path)
                == root.appending(path: "Sources/My Dir").standardizedFileURL)
    }

    @Test("a compiler's line and column name the file")
    func location() {
        let file = root.appending(path: "Sources/a.swift")
        #expect(ShellTerminalView.fileLink("Sources/a.swift:12", cwd: root.path) == file)
        #expect(ShellTerminalView.fileLink("Sources/a.swift:12:4", cwd: root.path) == file)
    }

    @Test("a missing file, a relative path with no directory, or a web link is not a file")
    func notFiles() {
        #expect(ShellTerminalView.fileLink("Sources/b.swift", cwd: root.path) == nil)
        #expect(ShellTerminalView.fileLink("Sources/a.swift", cwd: nil) == nil)
        #expect(ShellTerminalView.fileLink("https://swift.org/a.swift", cwd: root.path) == nil)
    }

    @Test("a folder opens; a package is selected, not launched")
    func folders() {
        #expect(ShellTerminalView.isPlainFolder(root.appending(path: "Sources")))
        #expect(!ShellTerminalView.isPlainFolder(root.appending(path: "Sources/a.swift")))
        #expect(!ShellTerminalView.isPlainFolder(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }
}
