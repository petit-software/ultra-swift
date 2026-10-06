import Foundation

/// Where the first window of a launch opens.
public enum WorkspaceLaunch {

    /// A bundled app is launched by `launchd` with "/" as its working directory, so the cwd
    /// says nothing about intent and the app would otherwise open on the filesystem root.
    /// Falling back to home meant every launch landed in `$HOME` however many projects had
    /// been opened — Open Folder every single time, which is not a feature, it is a chore.
    ///
    /// - A cwd that is not "/" was chosen BY someone: the app was launched from a terminal
    ///   sitting in a directory, and that beats any remembered project — and any standing
    ///   preference, because it is a choice made about THIS launch rather than about
    ///   launches in general.
    /// - Then `preferred`, the folder the user named in Settings. Above the recents on
    ///   purpose: the whole reason to set it is that the most recent project is NOT where
    ///   you want to start, and a preference the recents can outvote is a preference that
    ///   appears to do nothing.
    /// - Otherwise the most recent project that STILL EXISTS. A project that has been moved
    ///   or deleted is skipped rather than opened, because a window onto a path that is gone
    ///   restores panes whose cwd cannot be entered, and the app looks broken rather than
    ///   the folder looking missing.
    /// - Home only when there is nothing else.
    ///
    /// Every rung is checked for existence, `preferred` included: a default folder that has
    /// since been renamed must fall through like anything else rather than open a window
    /// onto a path that is not there.
    ///
    /// `excluding` is the projects already open: a NEW window skips them, since a project
    /// is open in one place, and takes the first rung that is free. Home is the floor
    /// whether or not it is open; the caller can see that it was excluded and decide.
    public static func directory(cwd: String,
                                 preferred: String? = nil,
                                 recents: [String],
                                 home: String,
                                 excluding: Set<String> = [],
                                 exists: (String) -> Bool) -> String {
        func free(_ path: String) -> Bool {
            exists(path) && !excluding.contains(WorkspaceDocument.canonical(path))
        }
        if cwd != "/", free(cwd) { return cwd }
        if let preferred, !preferred.isEmpty, free(preferred) { return preferred }
        if let recent = recents.first(where: free) { return recent }
        return home
    }

    /// What opening a project in a window amounts to.
    public enum Opening: Equatable, Sendable {
        /// This window already has it: show it.
        case select
        /// Another window has it on screen: go there.
        case raise
        /// It is still running, and no window has it — the window it was in has closed.
        /// The window asking takes it as it is, shells and all.
        case adopt
        /// It is not running anywhere: build it, from its saved layout if it has one.
        case make
    }

    /// Where a project being opened already is, which decides what opening it does.
    ///
    /// - `here`: the projects the window asking already holds.
    /// - `elsewhere`: the projects other windows hold.
    /// - `running`: every project with a live workspace, held or not.
    ///
    /// A project is open in ONE place: two workspaces on one folder restore the same
    /// document and both persist to it, so the last one touched overwrites the other's
    /// layout. Hence `select` and `raise` rather than a second copy.
    ///
    /// `adopt` is the case that was missing. Closing a window does not stop its shells —
    /// a pane's process outlives its window — so its workspaces go on running with
    /// nothing showing them. "Running" was being read as "on screen": opening such a
    /// project found it, looked for the window it was in, and with that gone did nothing
    /// at all, leaving the window on whichever project it had been showing.
    public static func opening(_ directory: String, here: [String], elsewhere: [String],
                               running: [String]) -> Opening {
        let wanted = WorkspaceDocument.canonical(directory)
        let has = { (paths: [String]) in
            paths.contains { WorkspaceDocument.canonical($0) == wanted }
        }
        if has(here) { return .select }
        if has(elsewhere) { return .raise }
        if has(running) { return .adopt }
        return .make
    }
}
