import Foundation
import JavaScriptCore
import Testing
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTiles

@Suite("Browser address")
struct BrowserAddressTests {

    @Test("a URL with a scheme loads as written")
    func withScheme() {
        #expect(BrowserAddress.url(from: "https://example.com/a?b=1")?.absoluteString
                == "https://example.com/a?b=1")
        #expect(BrowserAddress.url(from: "http://localhost:3000")?.absoluteString
                == "http://localhost:3000")
        #expect(BrowserAddress.url(from: "  https://swift.org  ")?.absoluteString
                == "https://swift.org")
    }

    @Test("a local address gets plain HTTP, because a dev server rarely speaks TLS")
    func localGetsHTTP() {
        #expect(BrowserAddress.url(from: "localhost:3000")?.absoluteString
                == "http://localhost:3000")
        #expect(BrowserAddress.url(from: "localhost")?.absoluteString == "http://localhost")
        #expect(BrowserAddress.url(from: "127.0.0.1:8080/api")?.absoluteString
                == "http://127.0.0.1:8080/api")
        #expect(BrowserAddress.url(from: "192.168.1.20:5173")?.absoluteString
                == "http://192.168.1.20:5173")
        #expect(BrowserAddress.url(from: "myapp.local")?.absoluteString == "http://myapp.local")
        #expect(BrowserAddress.url(from: "api.localhost:4000")?.absoluteString
                == "http://api.localhost:4000")
    }

    @Test("anything else that looks like a host gets HTTPS")
    func remoteGetsHTTPS() {
        #expect(BrowserAddress.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(BrowserAddress.url(from: "docs.swift.org/swift-book")?.absoluteString
                == "https://docs.swift.org/swift-book")
        // A public address is not local just for being numeric.
        #expect(BrowserAddress.url(from: "8.8.8.8")?.absoluteString == "https://8.8.8.8")
    }

    @Test("a path is a file on this machine")
    func paths() {
        #expect(BrowserAddress.url(from: "/tmp/index.html")?.isFileURL == true)
        #expect(BrowserAddress.url(from: "~/site/index.html")?.path.hasPrefix("/") == true)
    }

    @Test("text that is not an address is refused, not searched for")
    func refusesNonAddresses() {
        #expect(BrowserAddress.url(from: "") == nil)
        #expect(BrowserAddress.url(from: "   ") == nil)
        #expect(BrowserAddress.url(from: "how do I exit vim") == nil)
        #expect(BrowserAddress.url(from: "swift") == nil)
        #expect(BrowserAddress.url(from: "ftp://example.com") == nil)
    }

    @Test("a loaded page reads back the way it was typed")
    func display() {
        #expect(BrowserAddress.display(URL(string: "http://localhost:3000/")!)
                == "http://localhost:3000")
        #expect(BrowserAddress.display(URL(string: "https://example.com/a/")!)
                == "https://example.com/a/")
    }
}

@Suite("Browser pane record")
@MainActor
struct BrowserRecordTests {

    @Test("the record keeps the URL, the page title and the host, so a restore reopens the page")
    func record() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let record = TileFactory.browserRecord(url: URL(string: "http://localhost:3000/login"),
                                               title: "Sign in", root: root)
        #expect(record.kind == .browser)
        #expect(record.command == "http://localhost:3000/login")
        #expect(record.title == "Sign in")
        #expect(record.subtitle == "localhost:3000")
        #expect(record.icon == "globe")
    }

    @Test("the page's mode is the pane's appearance, so the whole pane matches the page")
    func darkRecord() {
        let root = URL(fileURLWithPath: "/tmp")
        let url = URL(string: "http://localhost:3000")
        let dark = TileFactory.browserRecord(url: url, title: nil, isDark: true, root: root)
        let light = TileFactory.browserRecord(url: url, title: nil, root: root)
        #expect(dark.appearance == .dark)
        #expect(light.appearance == .light)
    }

    @Test("a restored dark pane comes back dark")
    func restoreDark() {
        let paneID = PaneID()
        let saved = TileFactory.browserRecord(url: URL(string: "http://localhost:3000"),
                                              title: nil, isDark: true,
                                              root: URL(fileURLWithPath: "/tmp"))
        let factory = TileFactory(context: .inert(), restoring: [paneID: saved])
        _ = factory.makeContent(for: paneID)
        #expect(factory.browserSession(for: paneID)?.isDark == true)
    }

    @Test("switching a pane dark changes its saved record")
    func toggleUpdatesRecord() {
        let paneID = PaneID()
        let saved = TileFactory.browserRecord(url: URL(string: "http://localhost:3000"),
                                              title: nil, root: URL(fileURLWithPath: "/tmp"))
        let factory = TileFactory(context: .inert(), restoring: [paneID: saved])
        var changed: PaneRecord?
        factory.onRecordChange = { _, record in changed = record }
        _ = factory.makeContent(for: paneID)
        factory.browserSession(for: paneID)?.setDark(true)
        #expect(changed?.appearance == .dark)
    }

    @Test("the dark-page script parses, in both modes", arguments: [true, false])
    func darkScriptParses(isDark: Bool) throws {
        // Parsed, not run: `new Function` compiles the source without executing it, so a
        // syntax error — the kind a Swift raw string makes easy — fails here, not silently
        // inside a web page where nothing reports it.
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }
        let source = BrowserSession.darkScript(isDark: isDark)
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        context.evaluateScript("new Function(source)")
        #expect(failure == nil)
        #expect(source.contains("__ultraSetDark(\(isDark))"))
    }

    @Test("an empty pane is called Browser and has nothing to reopen")
    func emptyRecord() {
        let record = TileFactory.browserRecord(url: nil, title: nil,
                                               root: URL(fileURLWithPath: "/tmp"))
        #expect(record.title == "Browser")
        #expect(record.command == nil)
        #expect(record.subtitle == nil)
    }

    @Test("a restored browser pane comes back on its page")
    func restore() {
        let paneID = PaneID()
        let saved = TileFactory.browserRecord(url: URL(string: "https://example.com/docs"),
                                              title: "Docs", root: URL(fileURLWithPath: "/tmp"))
        let factory = TileFactory(context: .inert(), restoring: [paneID: saved])
        let built = factory.makeContent(for: paneID)
        #expect(built?.record.kind == .browser)
        #expect(factory.browserSession(for: paneID)?.requestedURL?.absoluteString
                == "https://example.com/docs")
    }
}

@Suite("Browser tabs")
@MainActor
struct BrowserTabsTests {
    private let root = URL(fileURLWithPath: "/tmp/project")
    private let server = URL(string: "http://localhost:3000")!
    private let docs = URL(string: "https://example.com/docs")!
    private let api = URL(string: "https://example.com/api")!

    @Test("a pane starts as one empty tab, and its last tab cannot be closed")
    func startsWithOne() {
        let tabs = BrowserTabs()
        #expect(tabs.sessions.count == 1)
        #expect(tabs.selected.requestedURL == nil)
        #expect(!tabs.canClose)
        tabs.closeSelected()
        #expect(tabs.sessions.count == 1)
    }

    @Test("a new tab goes last, is the one showing, and takes the pane's mode")
    func newTab() {
        let tabs = BrowserTabs(urls: [server], isDark: true)
        let first = tabs.selectedID
        let added = tabs.newTab()
        #expect(tabs.sessions.map(\.id) == [first, added.id])
        #expect(tabs.selectedID == added.id)
        #expect(added.requestedURL == nil)
        #expect(added.isDark)
        #expect(tabs.canClose)
    }

    @Test("closing the showing tab lands on the one before it")
    func closeLandsOnNeighbour() {
        let tabs = BrowserTabs(urls: [server, docs, api], selected: 2)
        let ids = tabs.sessions.map(\.id)
        tabs.closeSelected()
        #expect(tabs.selectedID == ids[1])
        // Closing a tab that is not showing leaves the selection where it was.
        tabs.close(ids[0])
        #expect(tabs.sessions.map(\.id) == [ids[1]])
        #expect(tabs.selectedID == ids[1])
    }

    @Test("next and previous wrap round the row")
    func stepping() {
        let tabs = BrowserTabs(urls: [server, docs, api])
        let ids = tabs.sessions.map(\.id)
        tabs.selectPrevious()
        #expect(tabs.selectedID == ids[2])
        tabs.selectNext()
        #expect(tabs.selectedID == ids[0])
        tabs.selectNext()
        #expect(tabs.selectedID == ids[1])
    }

    @Test("the mode is the pane's: set on one tab, it reaches the rest")
    func darkIsShared() {
        let tabs = BrowserTabs(urls: [server, docs, api])
        tabs.sessions[1].setDark(true)
        #expect(tabs.sessions.allSatisfy { $0.isDark })
        #expect(tabs.isDark)
        tabs.selected.toggleDark()
        #expect(tabs.sessions.allSatisfy { !$0.isDark })
    }

    @Test("a link that asks for a window of its own opens a tab")
    func linkOpensTab() {
        let tabs = BrowserTabs(urls: [server])
        tabs.selected.openInNewTab?(docs)
        #expect(tabs.sessions.count == 2)
        #expect(tabs.selected.requestedURL == docs)
    }

    @Test("one tab saves no state; several save their pages, in order, and which is showing")
    func state() throws {
        #expect(BrowserTabs(urls: [server]).state.encoded == nil)

        let tabs = BrowserTabs(urls: [server, nil, docs], selected: 2)
        let data = try #require(tabs.state.encoded)
        let state = try #require(BrowserPaneState.decode(data))
        #expect(state.tabs == [server.absoluteString, nil, docs.absoluteString])
        #expect(state.selected == 2)
        // The same tabs are the same bytes, so an unchanged record is not written again.
        #expect(tabs.state.encoded == data)
        #expect(BrowserPaneState.decode(nil) == nil)
        #expect(BrowserPaneState.decode(Data("not json".utf8)) == nil)
    }

    @Test("the record is the showing tab's, and follows the selection")
    func recordFollowsSelection() {
        let paneID = PaneID()
        let factory = TileFactory(context: .inert(root: root))
        factory.stage(.browser)
        factory.stage(browse: server)
        var changed: PaneRecord?
        factory.onRecordChange = { _, record in changed = record }
        let built = factory.makeContent(for: paneID)
        #expect(built?.record.command == server.absoluteString)
        #expect(built?.record.tileState == nil)

        let tabs = try! #require(factory.browserTabs(for: paneID))
        tabs.newTab(url: docs)
        #expect(changed?.command == docs.absoluteString)
        #expect(changed?.subtitle == "example.com")
        #expect(BrowserPaneState.decode(changed?.tileState)?.tabs.count == 2)
        #expect(factory.browserSession(for: paneID)?.requestedURL == docs)

        tabs.selectPrevious()
        #expect(changed?.command == server.absoluteString)
        #expect(BrowserPaneState.decode(changed?.tileState)?.selected == 0)

        // Back to one tab, back to a record with no state of its own.
        tabs.close(tabs.sessions[1].id)
        #expect(changed?.tileState == nil)
    }

    @Test("a restored pane comes back with every tab, on the one that was showing")
    func restore() {
        let paneID = PaneID()
        let state = BrowserPaneState(tabs: [server.absoluteString, docs.absoluteString, nil],
                                     selected: 1)
        let saved = TileFactory.browserRecord(url: docs, title: "Docs", isDark: true,
                                              tabs: state, root: root)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        let built = factory.makeContent(for: paneID)
        let tabs = try! #require(factory.browserTabs(for: paneID))
        #expect(tabs.sessions.map(\.requestedURL) == [server, docs, nil])
        #expect(tabs.selected.requestedURL == docs)
        #expect(tabs.sessions.allSatisfy { $0.isDark })
        // The page titles are not saved, so the header reads "Browser" until the page loads;
        // everything else about the record is what was written.
        #expect(built?.record.command == saved.command)
        #expect(built?.record.tileState == saved.tileState)
        #expect(built?.record.appearance == .dark)
    }

    @Test("a record from before panes had tabs restores as its one page")
    func restoreLegacy() {
        let paneID = PaneID()
        let saved = TileFactory.browserRecord(url: docs, title: "Docs", root: root)
        #expect(saved.tileState == nil)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        _ = factory.makeContent(for: paneID)
        #expect(factory.browserTabs(for: paneID)?.sessions.map(\.requestedURL) == [docs])
    }

    @Test("closing the pane closes every tab and forgets them")
    func release() {
        let paneID = PaneID()
        let factory = TileFactory(context: .inert(root: root))
        factory.stage(.browser)
        _ = factory.makeContent(for: paneID)
        factory.browserTabs(for: paneID)?.newTab(url: docs)
        factory.release(paneID)
        #expect(factory.browserTabs(for: paneID) == nil)
        #expect(factory.browserSession(for: paneID) == nil)
    }
}
