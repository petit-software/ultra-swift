import Testing
import Foundation
@testable import UltraCore

/// The list a release ships beside its DMG, and the launch that shows it.
@Suite("What's new")
struct WhatsNewTests {

    @Test("the asset's lines become items, markers and headings and blanks taken off")
    func items() {
        let text = """
        # What's new in 0.32.0

        - A window that closes keeps its sessions, and gives them back
        * ⌘W on a project's last pane closes the project
        • Close Session, in the palette

        The thinking star
        -
        """
        #expect(WhatsNew.items(in: text) == [
            "A window that closes keeps its sessions, and gives them back",
            "⌘W on a project's last pane closes the project",
            "Close Session, in the palette",
            "The thinking star",
        ])
        #expect(WhatsNew.items(in: "").isEmpty)
    }

    @Test("the asset and the page are found from the update feed, or from the repository")
    func urls() {
        let feed = "https://github.com/acme/ultra/releases/latest/download/appcast.xml"
        #expect(WhatsNew.assetURL(version: "0.32.0", feed: feed)?.absoluteString
                == "https://github.com/acme/ultra/releases/download/v0.32.0/whats-new.md")
        #expect(WhatsNew.pageURL(version: "0.32.0", feed: feed)?.absoluteString
                == "https://github.com/acme/ultra/releases/tag/v0.32.0")
        #expect(WhatsNew.assetURL(version: "0.32.0", feed: nil)?.absoluteString
                == WhatsNew.defaultReleases + "/download/v0.32.0/whats-new.md")
    }
}
