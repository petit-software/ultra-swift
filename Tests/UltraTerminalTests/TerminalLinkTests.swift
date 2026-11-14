import AppKit
import Testing
@testable import UltraTerminal
import UltraDesign

@Suite("Links clicked in a terminal")
struct TerminalLinkTests {
    private let page = LinkTarget.web(URL(string: "http://localhost:3000/docs")!)
    private let file = LinkTarget.file(URL(fileURLWithPath: "/tmp/a.swift"))
    private let folder = LinkTarget.folder(URL(fileURLWithPath: "/tmp"))

    @Test("asking shows the menu; the setting can open in Ultra or on the Mac instead")
    func clickRule() {
        #expect(TerminalLinkMenu.clickAction(for: page, modifiers: [.command], preference: .ask) == nil)
        #expect(TerminalLinkMenu.clickAction(for: file, modifiers: [.command], preference: .ask) == nil)
        #expect(TerminalLinkMenu.clickAction(for: page, modifiers: [.command], preference: .ultra) == .openInUltra)
        #expect(TerminalLinkMenu.clickAction(for: file, modifiers: [.command], preference: .ultra) == .openInUltra)
        #expect(TerminalLinkMenu.clickAction(for: folder, modifiers: [.command], preference: .ultra) == .showInFinder)
        #expect(TerminalLinkMenu.clickAction(for: page, modifiers: [.command], preference: .system) == .openInBrowser)
        #expect(TerminalLinkMenu.clickAction(for: file, modifiers: [.command], preference: .system) == .showInFinder)
    }

    @Test("⌥⌘-click skips the menu for the default browser or the file's app")
    func optionEscapes() {
        for preference in Preferences.LinkClick.allCases {
            #expect(TerminalLinkMenu.clickAction(for: page, modifiers: [.command, .option], preference: preference) == .openInBrowser)
            #expect(TerminalLinkMenu.clickAction(for: file, modifiers: [.command, .option], preference: preference) == .openWithDefaultApp)
        }
    }

    @Test("the menu offers Ultra and the Mac, and a folder only Finder")
    func rows() {
        #expect(TerminalLinkMenu.actions(for: page) == [.openInUltra, .openInBrowser, nil, .copy])
        #expect(TerminalLinkMenu.actions(for: file) == [.openInUltra, .showInFinder, .openWithDefaultApp, nil, .copy])
        #expect(TerminalLinkMenu.actions(for: folder) == [.showInFinder, nil, .copy])
        #expect(TerminalLinkMenu.title(of: .openInBrowser, for: page) == "Open in Browser")
        #expect(TerminalLinkMenu.title(of: .openWithDefaultApp, for: file, defaultApp: "Xcode") == "Open with Xcode")
        #expect(TerminalLinkMenu.title(of: .showInFinder, for: folder) == "Open in Finder")
        #expect(TerminalLinkMenu.fallback(for: page) == .openInBrowser)
        #expect(TerminalLinkMenu.fallback(for: file) == .showInFinder)
    }

    @Test("a web link is a page; anything else that is not a file is nothing")
    func targets() {
        #expect(ShellTerminalView.linkTarget("https://swift.org", cwd: nil) == .web(URL(string: "https://swift.org")!))
        #expect(ShellTerminalView.linkTarget("mailto:a@b.c", cwd: nil) == nil)
        #expect(ShellTerminalView.linkTarget("/no/such/file", cwd: nil) == nil)
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
