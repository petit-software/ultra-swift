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
        let light = TileFactory.chatRecord(for: store.current, isLight: true, root: root)
        let plain = TileFactory.chatRecord(for: store.current, root: root)
        #expect(light.appearance == .light)
        #expect(plain.appearance == nil)
        #expect(light.kind == .chat)
    }

    @Test("a restored light pane comes back light")
    func restoreLight() {
        let root = scratchRoot()
        let paneID = PaneID()
        let saved = TileFactory.chatRecord(for: ChatStore(root: root).current, isLight: true, root: root)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        _ = factory.makeContent(for: paneID)
        #expect(factory.chatStore(for: paneID)?.isLight == true)
    }

    @Test("switching a pane light changes its saved record, and back again clears it")
    func toggleUpdatesRecord() {
        let root = scratchRoot()
        let paneID = PaneID()
        let saved = TileFactory.chatRecord(for: ChatStore(root: root).current, root: root)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        var changed: PaneRecord?
        factory.onRecordChange = { _, record in changed = record }
        _ = factory.makeContent(for: paneID)
        let store = try? #require(factory.chatStore(for: paneID))
        store?.toggleLight()
        #expect(changed?.appearance == .light)
        store?.toggleLight()
        #expect(changed?.appearance == nil)
        #expect(changed?.kind == .chat)
    }
}
