import Testing
import Foundation
@testable import UltraCore

/// Where the first window opens. Before this, a bundled launch always landed in `$HOME`
/// however many projects had been opened, because `launchd` hands the app "/" as its cwd
/// and "/" was read as "no opinion, use home" rather than "no opinion, use the last project".
@Suite("Launch directory")
struct WorkspaceLaunchTests {

    private let home = "/Users/x"
    private func alwaysExists(_: String) -> Bool { true }

    @Test("with nothing remembered, home")
    func fallsBackToHome() {
        #expect(WorkspaceLaunch.directory(cwd: "/", recents: [], home: home,
                                          exists: alwaysExists) == home)
    }

    @Test("a bundled launch reopens the most recent project")
    func reopensMostRecent() {
        #expect(WorkspaceLaunch.directory(cwd: "/", recents: ["/p/alpha", "/p/beta"],
                                          home: home, exists: alwaysExists) == "/p/alpha")
    }

    /// Launching from a terminal sitting in a directory is an explicit choice about where to
    /// work, and it beats anything remembered.
    @Test("a real cwd wins over the remembered project")
    func cwdWins() {
        #expect(WorkspaceLaunch.directory(cwd: "/p/gamma", recents: ["/p/alpha"],
                                          home: home, exists: alwaysExists) == "/p/gamma")
    }

    /// A project that has been moved or deleted is skipped, not opened. Restoring onto a
    /// path that is gone gives panes a cwd they cannot enter, and the app looks broken
    /// rather than the folder looking missing.
    @Test("a project that no longer exists is skipped")
    func skipsMissing() {
        let live = Set(["/p/beta"])
        #expect(WorkspaceLaunch.directory(cwd: "/", recents: ["/p/alpha", "/p/beta"],
                                          home: home, exists: { live.contains($0) }) == "/p/beta")
    }

    @Test("every remembered project missing still lands somewhere usable")
    func allMissingFallsBackToHome() {
        #expect(WorkspaceLaunch.directory(cwd: "/", recents: ["/p/alpha"], home: home,
                                          exists: { _ in false }) == home)
    }

    /// A cwd that no longer exists is not a reason to open nothing — it falls through to the
    /// same ladder as an unopinionated launch.
    @Test("a cwd that has vanished falls through to the recents")
    func vanishedCwdFallsThrough() {
        #expect(WorkspaceLaunch.directory(cwd: "/p/gone", recents: ["/p/alpha"], home: home,
                                          exists: { $0 == "/p/alpha" }) == "/p/alpha")
    }

    // MARK: - The chosen folder

    /// The reason the setting exists: one project sits at the front of the recents forever,
    /// so "most recent" stops being a guess and becomes the same answer every launch.
    @Test("a chosen folder beats the most recent project")
    func preferredBeatsRecents() {
        #expect(WorkspaceLaunch.directory(cwd: "/", preferred: "/p/chosen",
                                          recents: ["/p/alpha"], home: home,
                                          exists: alwaysExists) == "/p/chosen")
    }

    /// Launching from a terminal is a decision about THIS launch; the setting is a decision
    /// about launches in general. The specific one wins.
    @Test("a real cwd still beats the chosen folder")
    func cwdBeatsPreferred() {
        #expect(WorkspaceLaunch.directory(cwd: "/p/gamma", preferred: "/p/chosen",
                                          recents: [], home: home,
                                          exists: alwaysExists) == "/p/gamma")
    }

    /// Unset is the default, and must mean "carry on guessing" rather than "open nothing".
    @Test("no chosen folder leaves the old ladder exactly as it was")
    func unsetChangesNothing() {
        #expect(WorkspaceLaunch.directory(cwd: "/", preferred: "", recents: ["/p/alpha"],
                                          home: home, exists: alwaysExists) == "/p/alpha")
        #expect(WorkspaceLaunch.directory(cwd: "/", preferred: nil, recents: ["/p/alpha"],
                                          home: home, exists: alwaysExists) == "/p/alpha")
    }

    /// Checked for existence like every other rung. A folder chosen last year and renamed
    /// since must not open a window onto a path that is gone.
    @Test("a chosen folder that no longer exists falls through")
    func missingPreferredFallsThrough() {
        #expect(WorkspaceLaunch.directory(cwd: "/", preferred: "/p/renamed",
                                          recents: ["/p/alpha"], home: home,
                                          exists: { $0 == "/p/alpha" }) == "/p/alpha")
        #expect(WorkspaceLaunch.directory(cwd: "/", preferred: "/p/renamed", recents: [],
                                          home: home, exists: { _ in false }) == home)
    }
}
