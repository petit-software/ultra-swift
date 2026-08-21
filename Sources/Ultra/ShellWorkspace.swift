import AppKit
import Foundation
import UltraCanvas
import UltraCore
import UltraDesign
import UltraLayout
import UltraTerminal

/// Builds a workspace whose panes are real shells.
///
/// This is the only place `UltraCanvas` and `UltraTerminal` meet: the canvas asks for
/// content by `PaneID`, the terminal layer supplies it. Neither imports the other.
@MainActor
enum ShellWorkspace {

    /// - Parameter restore: whether to adopt the saved layout. False for a new TAB, which
    ///   is new work — restoring into it would clone the panes already on screen.
    static func make(storage: WorkspaceStorage,
                     directory: String,
                     theme: TerminalTheme = .dark,
                     restore: Bool = true) -> LayoutStore {
        let document = restore ? storage.loadAll().first : nil
        let records: [PaneID: PaneRecord] = document.map { document in
            Dictionary(uniqueKeysWithValues: document.panes.compactMap { key, value in
                PaneID(uuidString: key).map { ($0, value) }
            })
        } ?? [:]

        let factory = ShellPaneFactory(theme: theme, defaultDirectory: directory,
                                       restoring: records)

        let store = LayoutStore(tree: document?.tree ?? LayoutTree(single: PaneID()),
                                theme: theme,
                                workspaceID: document?.id ?? UUID(),
                                storage: storage) { paneID in
            let content = factory.makeContent(for: paneID)
            return PaneContent(view: content.view, record: content.record)
        }

        store.workspaceTitle = document?.title
            ?? URL(fileURLWithPath: directory).lastPathComponent
        store.workspaceSubtitle = document?.subtitle ?? ShellPaneFactory.abbreviate(directory)
        store.windowFrame = document?.windowFrame?.rect

        // Closing a pane is the only thing that kills its PTY.
        store.surfaces.onRelease = { [weak factory] paneID in factory?.release(paneID) }
        // Once geometry stops moving, every shell gets its authoritative size.
        store.onGeometrySettled = { [weak factory] in factory?.commitResize() }
        // A shell renames its own pane as it runs; the header follows.
        factory.onDescriptorChange = { [weak store] paneID, record in
            store?.surfaces.updateRecord(record, for: paneID)
            store?.persist()
        }

        // Keyed by workspace, not a singleton: with tabs there are several live factories
        // at once and a menu command must reach the one belonging to the focused tab.
        Registry.factories[store.workspaceID] = factory
        return store
    }

    /// The live factory, so menu commands can reach the shells.
    enum Registry {
        @MainActor static var factories: [UUID: ShellPaneFactory] = [:]
    }

    /// Launch the next new pane as an agent rather than a plain shell.
    static func stageAgent(_ agent: AgentDefinition?, for store: LayoutStore) {
        Registry.factories[store.workspaceID]?.stageAgent(agent)
    }

    /// Agents that are actually installed, probed through a login shell.
    static func availableAgents() -> [AgentDefinition] {
        AgentDefinition.builtIns.filter { ShellLauncher.isAvailable($0.binary) }
    }
}
