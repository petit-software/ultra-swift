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

/// A new window skips the projects that are open already: a project is open in one place.
@Suite("Launch directory for a new window")
struct WorkspaceLaunchExclusionTests {

    private let home = "/Users/x"
    private func alwaysExists(_: String) -> Bool { true }

    @Test("an open preferred folder yields to the first free recent")
    func skipsOpenProjects() {
        let directory = WorkspaceLaunch.directory(cwd: "/", preferred: "/p/pref",
                                                  recents: ["/p/alpha", "/p/beta"], home: home,
                                                  excluding: ["/p/pref", "/p/alpha"],
                                                  exists: alwaysExists)
        #expect(directory == "/p/beta")
    }

    @Test("an open cwd is skipped like any other rung, and spelling does not matter")
    func cwdExcludedCanonically() {
        let directory = WorkspaceLaunch.directory(cwd: "/p/gamma/", recents: ["/p/alpha"],
                                                  home: home, excluding: ["/p/gamma"],
                                                  exists: alwaysExists)
        #expect(directory == "/p/alpha")
    }

    @Test("home is the floor even when it is open")
    func homeIsTheFloor() {
        let directory = WorkspaceLaunch.directory(cwd: "/", recents: [home], home: home,
                                                  excluding: [home], exists: alwaysExists)
        #expect(directory == home)
    }
}

/// What opening a project does depends on where it already is. The case these exist for is
/// the last but one: a project still running from a window that has closed used to be
/// found, looked for on screen, and — with no window to raise — left alone, so opening it
/// did nothing and the window stayed on the project it had been showing.
@Suite("Opening a project")
struct WorkspaceOpeningTests {

    @Test("a project this window holds is shown, not opened twice")
    func selectsHere() {
        #expect(WorkspaceLaunch.opening("/p/alpha", here: ["/p/alpha"], elsewhere: [],
                                        running: ["/p/alpha"]) == .select)
    }

    @Test("a project another window holds is raised there")
    func raisesElsewhere() {
        #expect(WorkspaceLaunch.opening("/p/alpha", here: ["/p/beta"], elsewhere: ["/p/alpha"],
                                        running: ["/p/alpha", "/p/beta"]) == .raise)
    }

    @Test("a project running in no window is taken by the window that asks")
    func adoptsRunning() {
        #expect(WorkspaceLaunch.opening("/p/alpha", here: ["/p/beta"], elsewhere: ["/p/gamma"],
                                        running: ["/p/alpha", "/p/beta", "/p/gamma"]) == .adopt)
    }

    @Test("a project that is not running is built")
    func makesNew() {
        #expect(WorkspaceLaunch.opening("/p/alpha", here: ["/p/beta"], elsewhere: [],
                                        running: ["/p/beta"]) == .make)
    }

    @Test("this window wins over another, and spelling does not matter")
    func hereWinsCanonically() {
        #expect(WorkspaceLaunch.opening("/p/alpha/", here: ["/p/alpha"], elsewhere: ["/p/alpha"],
                                        running: ["/p/alpha"]) == .select)
        #expect(WorkspaceLaunch.opening("/p/alpha/", here: [], elsewhere: [],
                                        running: ["/p/alpha"]) == .adopt)
    }
}
