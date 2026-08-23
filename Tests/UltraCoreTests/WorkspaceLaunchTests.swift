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
}
