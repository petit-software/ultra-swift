import Foundation
import UltraCore
import UltraDesign
import UltraTiles

/// `AgentInstructions` with the project's own answers filled in.
///
/// The core type takes paths; this is where they come from. The todo path in particular is
/// whatever a Todo pane on this project would open — an adopted `TODO.md`, a remembered
/// relocation — because an `AGENTS.md` that names a file the pane does not use sends the
/// agent and the user to two different lists.
@MainActor
enum ProjectInstructions {

    static func paths(for root: URL) -> AgentInstructions.Paths {
        let todo = TodoStore.currentLocation(for: root)
        return AgentInstructions.Paths(todo: AgentInstructions.displayPath(todo, relativeTo: root))
    }

    /// A project Ultra has just made. Everything, if the setting says so.
    static func installIfWanted(in root: URL) {
        guard Preferences.writesAgentInstructions else { return }
        try? AgentInstructions.install(in: root, paths: paths(for: root))
    }

    /// A project being opened. Only a section already there is touched — see
    /// `AgentInstructions.refresh`.
    static func refresh(in directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try? AgentInstructions.refresh(in: root, paths: paths(for: root))
    }

    /// File ▸ Session ▸ Write AGENTS.md: the user asked, so the answer is yes even for a
    /// project that was not created here. Returns the file, for the editor to show.
    static func install(in directory: String) throws -> URL {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try AgentInstructions.install(in: root, paths: paths(for: root))
        return root.appendingPathComponent(AgentInstructions.fileName)
    }
}
