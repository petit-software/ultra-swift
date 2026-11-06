import Foundation
import Testing
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTiles

/// A todo pane's look: the editor's and the chat's switch, saved with the pane and restored
/// with it. Not the list — the store's own tests cover that.
@Suite("Todo pane")
@MainActor
struct TodoPaneTests {

    private func scratchRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-todo-pane-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func todoRecord(root: URL, appearance: PaneRecord.Appearance? = nil) -> PaneRecord {
        var record = TileFactory.record(for: .todo, root: root)
        record.appearance = appearance
        return record
    }

    @Test("a restored light pane comes back light, and its record says so")
    func restoreLight() {
        let root = scratchRoot()
        let paneID = PaneID()
        let factory = TileFactory(context: .inert(root: root),
                                  restoring: [paneID: todoRecord(root: root, appearance: .light)])
        let content = factory.makeContent(for: paneID)
        #expect(factory.todoStore(for: paneID)?.pinnedAppearance == .light)
        #expect(content?.record.appearance == .light)
    }

    @Test("the switch pins the other look from the app's, saved on the record, and back again clears it")
    func toggleUpdatesRecord() {
        let root = scratchRoot()
        let paneID = PaneID()
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: todoRecord(root: root)])
        var changed: PaneRecord?
        factory.onRecordChange = { _, record in changed = record }
        _ = factory.makeContent(for: paneID)
        let store = try? #require(factory.todoStore(for: paneID))
        store?.toggleAppearance(appIsDark: true)
        #expect(changed?.appearance == .light)
        store?.toggleAppearance(appIsDark: true)
        #expect(changed?.appearance == nil)
        store?.toggleAppearance(appIsDark: false)
        #expect(changed?.appearance == .dark)
        #expect(changed?.kind == .todo)
    }
}
