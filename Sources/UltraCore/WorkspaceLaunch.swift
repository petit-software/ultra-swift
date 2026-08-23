import Foundation

/// Where the first window of a launch opens.
public enum WorkspaceLaunch {

    /// A bundled app is launched by `launchd` with "/" as its working directory, so the cwd
    /// says nothing about intent and the app would otherwise open on the filesystem root.
    /// Falling back to home meant every launch landed in `$HOME` however many projects had
    /// been opened — Open Folder every single time, which is not a feature, it is a chore.
    ///
    /// - A cwd that is not "/" was chosen BY someone: the app was launched from a terminal
    ///   sitting in a directory, and that beats any remembered project.
    /// - Otherwise the most recent project that STILL EXISTS. A project that has been moved
    ///   or deleted is skipped rather than opened, because a window onto a path that is gone
    ///   restores panes whose cwd cannot be entered, and the app looks broken rather than
    ///   the folder looking missing.
    /// - Home only when there is nothing else.
    public static func directory(cwd: String,
                                 recents: [String],
                                 home: String,
                                 exists: (String) -> Bool) -> String {
        if cwd != "/", exists(cwd) { return cwd }
        if let recent = recents.first(where: exists) { return recent }
        return home
    }
}
