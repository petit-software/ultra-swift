import Testing
import Foundation
import UltraDesign
@testable import UltraTiles

/// Markdown's two faces in the editor: the page it opens on, and the text one click away.
@Suite("Markdown reading mode", .serialized)
@MainActor
struct MarkdownReadingTests {

    /// A preference suite of its own per test, so the default under test is the one this
    /// test set and not one another suite left behind.
    private func withPreferences(_ body: () -> Void) {
        let name = "ultra.tests.reading.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite, body)
    }

    private func file(_ name: String, _ contents: String = "# Title\n") throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-reading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a Markdown file opens as a page by default; code opens as text")
    func markdownOpensReading() throws {
        let readme = try file("README.md")
        let swift = try file("main.swift", "let x = 1\n")
        withPreferences {
            let page = EditorDocument(url: readme)
            #expect(page.isMarkdown)
            #expect(page.isReading)
            let code = EditorDocument(url: swift)
            #expect(!code.isMarkdown)
            #expect(!code.isReading)
        }
    }

    @Test("the setting off, Markdown opens as text and can still be read as a page")
    func settingOffOpensText() throws {
        let readme = try file("notes.md")
        withPreferences {
            Preferences.opensMarkdownReading = false
            let page = EditorDocument(url: readme)
            #expect(!page.isReading)
            page.toggleReading()
            #expect(page.isReading, "the switch is per file, whatever the default")
        }
    }

    @Test("only Markdown has a page: a Swift file stays on its text when asked")
    func codeCannotRead() throws {
        let swift = try file("main.swift", "let x = 1\n")
        withPreferences {
            let code = EditorDocument(url: swift)
            code.setReading(true)
            #expect(!code.isReading)
        }
    }

    @Test("the sessions' switch acts on the Markdown tab showing and nothing else")
    func sessionsToggleActsOnMarkdown() throws {
        let readme = try file("README.md")
        let swift = try file("main.swift", "let x = 1\n")
        withPreferences {
            let open = EditorSessions()
            open.open(.file(readme))
            #expect(open.readableDocument != nil)
            open.toggleReading()
            #expect(open.readableDocument?.isReading == false)
            open.toggleReading()
            #expect(open.readableDocument?.isReading == true)

            open.open(.file(swift))
            #expect(open.readableDocument == nil)
            open.newFile()
            #expect(open.readableDocument == nil, "a new file has no name to be Markdown by")
        }
    }

    @Test("a fence's label finds the editor's language by extension or by name")
    func fenceLanguages() {
        #expect(EditorCodeSyntaxHighlighter.language(named: "swift")?.name == "Swift")
        #expect(EditorCodeSyntaxHighlighter.language(named: "python")?.name
                == CodeLanguage.detect(path: "x.py")?.name)
        #expect(EditorCodeSyntaxHighlighter.language(named: "bash")?.name
                == CodeLanguage.detect(path: "x.sh")?.name)
        #expect(EditorCodeSyntaxHighlighter.language(named: "") == nil)
        #expect(EditorCodeSyntaxHighlighter.language(named: "klingon") == nil)
    }
}
