import Testing
import Foundation
@testable import UltraCore

/// Starting a project that does not exist yet: an empty folder, or a clone.
///
/// The clone tests use a repository on disk rather than a URL. `git clone` treats a local
/// path exactly as it treats a remote one — same code path, same failures — so this is a
/// real clone with no network to be flaky about and no credentials to have.
@Suite("New project")
struct NewProjectTests {

    /// A directory of its own per test, removed afterwards. Nothing here writes anywhere the
    /// user can see.
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-newproject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - What a clone is called

    /// git's own rule — the last path component minus `.git` — across the spellings people
    /// actually paste. Offering the wrong name means the user has to retype it every time.
    @Test("a clone is named the way git would name it", arguments: [
        ("https://github.com/owner/repo.git", "repo"),
        ("https://github.com/owner/repo", "repo"),
        ("https://github.com/owner/repo/", "repo"),
        ("git@github.com:owner/repo.git", "repo"),
        ("ssh://git@host.example:2222/owner/repo.git", "repo"),
        ("/Users/someone/checkouts/repo", "repo"),
        ("file:///Users/someone/checkouts/repo.git", "repo"),
        // Copied out of a browser's address bar, which is where most URLs come from.
        ("https://github.com/owner/repo?tab=readme", "repo"),
        ("https://github.com/owner/repo#readme", "repo"),
        // A dot in the name is not a `.git` suffix.
        ("https://github.com/owner/repo.js", "repo.js"),
    ])
    func clonesAreNamedLikeGitNamesThem(url: String, expected: String) {
        #expect(NewProject.folderName(forRepository: url) == expected)
    }

    /// Nothing to go on is the sheet's cue to keep asking, not to invent a name.
    @Test("nothing to go on produces no name")
    func emptyUrlHasNoName() {
        #expect(NewProject.folderName(forRepository: "") == "")
        #expect(NewProject.folderName(forRepository: "   ") == "")
        #expect(NewProject.folderName(forRepository: "/") == "")
    }

    // MARK: - What a project may be called

    @Test("a name has to be one")
    func namesAreChecked() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(NewProject.problem(name: "", in: root) == .noName)
        #expect(NewProject.problem(name: "   ", in: root) == .noName)
        #expect(NewProject.problem(name: "a/b", in: root) == .separatorInName)
        #expect(NewProject.problem(name: ".", in: root) == .reservedName)
        #expect(NewProject.problem(name: "..", in: root) == .reservedName)
        #expect(NewProject.problem(name: "my-project", in: root) == nil)
        // Surrounding space is a paste artefact, not a decision.
        #expect(NewProject.problem(name: "  my-project  ", in: root) == nil)
        // A leading dot is a hidden folder, which is unusual but is not WRONG.
        #expect(NewProject.problem(name: ".config", in: root) == nil)
    }

    /// The two ways this fails in practice: a name already taken, and a location that has
    /// moved since the sheet opened.
    @Test("the location is checked too, not just the name")
    func locationIsChecked() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("taken"),
                                                withIntermediateDirectories: false)
        #expect(NewProject.problem(name: "taken", in: root) == .alreadyExists)

        // A FILE in the way stops the folder just as surely as a folder does.
        let file = root.appendingPathComponent("afile")
        try Data("x".utf8).write(to: file)
        #expect(NewProject.problem(name: "afile", in: root) == .alreadyExists)
        #expect(NewProject.problem(name: "anything", in: file) == .parentNotADirectory)

        #expect(NewProject.problem(name: "anything",
                                   in: root.appendingPathComponent("gone")) == .parentMissing)
    }

    /// Only "is there one". Everything else about a git URL is a question only `git clone`
    /// can answer, and a client-side pattern rejects the working URLs that do not look like
    /// the common ones.
    @Test("a repository URL is only checked for being there")
    func repositoryIsOnlyCheckedForBeingThere() {
        #expect(NewProject.problem(repository: "") == .noRepository)
        #expect(NewProject.problem(repository: "  ") == .noRepository)
        #expect(NewProject.problem(repository: "git@internal:8022/thing") == nil)
        #expect(NewProject.problem(repository: "../sibling") == nil)
    }

    // MARK: - Making a folder

    @Test("a new folder is created where it was asked for")
    func createsTheFolder() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NewProject.createFolder(named: "fresh", in: root, initializingGit: false)
        #expect(url == root.appendingPathComponent("fresh"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
    }

    @Test("a new folder can be a repository")
    func initializesGit() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NewProject.createFolder(named: "repo", in: root, initializingGit: true)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
    }

    /// Refused BEFORE anything is written. A create that half-happens and then reports a
    /// problem leaves the user to work out what state they are in.
    @Test("a refused name writes nothing")
    func refusedNameWritesNothing() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("taken"),
                                                withIntermediateDirectories: false)

        #expect(throws: NewProject.Failure.refused(.alreadyExists)) {
            try NewProject.createFolder(named: "taken", in: root, initializingGit: true)
        }
        #expect(throws: NewProject.Failure.refused(.separatorInName)) {
            try NewProject.createFolder(named: "a/b", in: root, initializingGit: false)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path),
                "a name with a separator must not quietly create the intermediate")
    }

    // MARK: - Cloning

    /// A real repository on disk, with one commit, for `git clone` to copy.
    private func makeOrigin(in root: URL) throws -> URL {
        let origin = root.appendingPathComponent("origin", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: origin.appendingPathComponent("README.md"))
        let git = try #require(NewProject.gitPath())
        for arguments in [["init", "--quiet"],
                          ["-c", "user.email=t@t", "-c", "user.name=T", "add", "."],
                          ["-c", "user.email=t@t", "-c", "user.name=T",
                           "commit", "--quiet", "-m", "first"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = arguments
            process.currentDirectoryURL = origin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        return origin
    }

    @Test("a clone lands where it was asked for, with the repository in it")
    func clones() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try makeOrigin(in: root)

        let result = await NewProject.clone(repository: origin.path, named: "copy", in: root)
        let url = try #require(try? result.get())
        #expect(url == root.appendingPathComponent("copy"))
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
    }

    /// Git's own words are the only ones worth showing — "Repository not found",
    /// "Permission denied (publickey)". A rewritten summary loses the line that says what to
    /// fix, so the failure has to carry the output.
    @Test("a clone that fails says what git said")
    func failedCloneCarriesTheOutput() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await NewProject.clone(repository: root.appendingPathComponent("nope").path,
                                            named: "copy", in: root)
        guard case .failure(.gitFailed(let status, let output)) = result else {
            Issue.record("expected git to fail, got \(result)")
            return
        }
        #expect(status != 0)
        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // The leftover is exactly what would make a retry with the same name report
        // "already there".
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copy").path))
    }

    @Test("a clone is refused before it starts when the name is taken")
    func cloneChecksTheNameFirst() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try makeOrigin(in: root)

        let result = await NewProject.clone(repository: origin.path, named: "origin", in: root)
        #expect(result == .failure(.refused(.alreadyExists)))
        // The check must not have removed what was already there.
        #expect(FileManager.default.fileExists(
            atPath: origin.appendingPathComponent("README.md").path))
    }

    @Test("a clone with no URL is refused")
    func cloneNeedsAUrl() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await NewProject.clone(repository: "  ", named: "copy", in: root)
                == .failure(.refused(.noRepository)))
    }
}
