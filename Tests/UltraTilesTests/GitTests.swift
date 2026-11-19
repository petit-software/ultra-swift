import Testing
import Foundation
@testable import UltraTiles

@Suite("Git")
@MainActor
struct GitTests {

    // MARK: Parsing

    /// Real `--porcelain=v2 --branch -z` output. NUL-separated, so records are joined here
    /// exactly as git emits them — including a rename, whose origin path is its own record.
    private var sample: String {
        [
            "# branch.oid abc123",
            "# branch.head feature/thing",
            "# branch.upstream origin/feature/thing",
            "# branch.ab +2 -3",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/edited.swift",
            "1 M. N... 100644 100644 100644 aaa bbb Sources/staged.swift",
            "1 MM N... 100644 100644 100644 aaa bbb Sources/both.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 Sources/new-name.swift",
            "Sources/old-name.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc Sources/conflict.swift",
            "? Sources/untracked.swift",
        ].joined(separator: "\0") + "\0"
    }

    @Test("branch, upstream and divergence parse")
    func branchLine() {
        let status = GitModel.parseStatus(sample)
        #expect(status.branch == "feature/thing")
        #expect(status.upstream == "origin/feature/thing")
        #expect(status.ahead == 2)
        #expect(status.behind == 3)
    }

    @Test("index and working-tree states are tracked separately")
    func separateStates() {
        let changes = GitModel.parseStatus(sample).changes
        let edited = try! #require(changes.first { $0.path == "Sources/edited.swift" })
        #expect(edited.staged == .unmodified)
        #expect(edited.unstaged == .modified)
        #expect(edited.isStaged == false)

        let staged = try! #require(changes.first { $0.path == "Sources/staged.swift" })
        #expect(staged.staged == .modified)
        #expect(staged.unstaged == .unmodified)
        #expect(staged.isStaged)

        // Staged, then edited again — the case collapsing the two states would lose.
        let both = try! #require(changes.first { $0.path == "Sources/both.swift" })
        #expect(both.staged == .modified)
        #expect(both.unstaged == .modified)
    }

    @Test("a rename's origin path is not reported as a separate file")
    func renameOriginSkipped() {
        let changes = GitModel.parseStatus(sample).changes
        #expect(changes.contains { $0.path == "Sources/new-name.swift" })
        #expect(!changes.contains { $0.path == "Sources/old-name.swift" },
                "the origin record must be consumed, not parsed as a file")
    }

    @Test("conflicts and untracked files are distinguished")
    func conflictsAndUntracked() {
        let changes = GitModel.parseStatus(sample).changes
        #expect(changes.first { $0.path == "Sources/conflict.swift" }?.staged == .conflicted)
        #expect(changes.first { $0.path == "Sources/untracked.swift" }?.staged == .untracked)
    }

    @Test("a detached HEAD is reported as no branch, not as a branch named '(detached)'")
    func detachedHead() {
        let status = GitModel.parseStatus("# branch.head (detached)\0")
        #expect(status.branch == nil)
    }

    @Test("worktree list parses, and the current one is marked")
    func worktrees() {
        let output = """
        worktree /Users/x/repo
        HEAD abc
        branch refs/heads/main

        worktree /Users/x/repo-feature
        HEAD def
        branch refs/heads/feature

        """
        let trees = GitModel.parseWorktrees(output, current: "/Users/x/repo-feature")
        #expect(trees.map(\.name) == ["repo", "repo-feature"])
        #expect(trees.map(\.branch) == ["main", "feature"])
        #expect(trees.first { $0.name == "repo-feature" }?.isCurrent == true)
        #expect(trees.first { $0.name == "repo" }?.isCurrent == false)
    }

    // MARK: Pull request

    /// What `gh pr view --json number,title,url,state,isDraft` actually prints.
    @Test("a pull request parses out of gh's json")
    func pullRequestParses() throws {
        let json = """
        {"isDraft":false,"number":42,"state":"OPEN",\
        "title":"Adding leads, removing is a minus",\
        "url":"https://github.com/petit-software/ultra-swift/pull/42"}
        """
        let pr = try #require(GitModel.parsePullRequest(json))
        #expect(pr.number == 42)
        #expect(pr.title == "Adding leads, removing is a minus")
        #expect(pr.url == "https://github.com/petit-software/ultra-swift/pull/42")
        #expect(pr.isOpen)
        #expect(!pr.isDraft)
    }

    @Test("a draft and a merged pull request keep the state gh reported")
    func pullRequestStates() throws {
        let draft = try #require(GitModel.parsePullRequest(
            #"{"isDraft":true,"number":7,"state":"OPEN","title":"wip","url":"https://x/pull/7"}"#))
        #expect(draft.isDraft)
        #expect(draft.isOpen)
        let merged = try #require(GitModel.parsePullRequest(
            #"{"isDraft":false,"number":8,"state":"MERGED","title":"done","url":"https://x/pull/8"}"#))
        #expect(!merged.isOpen)
        #expect(merged.state == "MERGED")
    }

    /// The ordinary case, not an error: no PR for the branch, no `gh` on the Mac, a
    /// signed-out user and a remote that is not GitHub all reach the tile as empty stdout.
    @Test("no pull request is nothing, not a broken row")
    func noPullRequest() {
        #expect(GitModel.parsePullRequest("") == nil)
        #expect(GitModel.parsePullRequest("no pull requests found for branch \"main\"") == nil)
        #expect(GitModel.parsePullRequest("{}") == nil)
        #expect(GitModel.parsePullRequest("[]") == nil)
    }

    /// A row that links nowhere is worse than no row: it looks clickable and does nothing.
    @Test("a pull request with no url is not offered")
    func urllessPullRequest() {
        #expect(GitModel.parsePullRequest(
            #"{"isDraft":false,"number":9,"state":"OPEN","title":"x","url":""}"#) == nil)
    }

    /// `gh` is looked for by path because a bundled app's `PATH` is launchd's, not a login
    /// shell's — Homebrew's bin is not on it.
    @Test("gh is found by path, and its absence is not an error")
    func ghLookup() {
        // Whatever this machine has: either a path ending in the binary, or nothing.
        #expect(GitModel.ghPath() == nil || GitModel.ghPath()?.hasSuffix("/gh") == true)
        // A manager that can see nothing stands in for a Mac without gh installed. The
        // tile must treat that as "no link to offer", not as a failure.
        #expect(GitModel.ghPath(fileManager: NoFilesManager()) == nil)
    }

    @Test("garbage does not produce changes")
    func robustness() {
        #expect(GitModel.parseStatus("").changes.isEmpty)
        #expect(GitModel.parseStatus("not git output at all\0").changes.isEmpty)
    }

    // MARK: Against a real repository

    /// The acceptance criterion is that the tile agrees with git. So ask git.
    @Test("a real repository reports the same branch and files git does")
    func againstRealRepo() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ arguments: [String]) {
            _ = CommandProbe.runSync("/usr/bin/git", ["-C", root.path] + arguments, timeout: 10)
        }
        git(["init", "-q", "-b", "trunk"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "T"])
        try "one".write(to: root.appendingPathComponent("committed.txt"),
                        atomically: true, encoding: .utf8)
        git(["add", "-A"])
        git(["commit", "-qm", "first"])

        // Now make one of each interesting state.
        try "changed".write(to: root.appendingPathComponent("committed.txt"),
                            atomically: true, encoding: .utf8)
        try "new".write(to: root.appendingPathComponent("staged.txt"),
                        atomically: true, encoding: .utf8)
        git(["add", "staged.txt"])
        try "loose".write(to: root.appendingPathComponent("untracked.txt"),
                          atomically: true, encoding: .utf8)

        let model = GitModel(root: root)
        await model.refresh()

        #expect(model.isRepository)
        #expect(model.branch == "trunk")
        #expect(model.operation == nil)
        #expect(Set(model.changes.map(\.path))
                == ["committed.txt", "staged.txt", "untracked.txt"])
        #expect(model.changes.first { $0.path == "staged.txt" }?.isStaged == true)
        #expect(model.changes.first { $0.path == "committed.txt" }?.unstaged == .modified)
        #expect(model.changes.first { $0.path == "untracked.txt" }?.staged == .untracked)
        #expect(model.worktrees.count == 1)
        #expect(model.worktrees.first?.isCurrent == true)

        // Staging through the tile must agree with git afterwards.
        let dirty = try #require(model.changes.first { $0.path == "committed.txt" })
        await model.stage(dirty)
        #expect(model.changes.first { $0.path == "committed.txt" }?.isStaged == true)
    }

    @Test("a directory that is not a repository is reported as such, not as an empty repo")
    func notARepository() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GitModel(root: root)
        await model.refresh()
        #expect(model.isRepository == false)
        #expect(model.branch == nil)
    }
}

@Suite("Git diffs", .serialized)
@MainActor
struct GitDiffTests {

    /// A throwaway repository, so the assertions are against real git output rather than a
    /// fixture that drifts from what git actually prints.
    private func makeRepo() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
        }
        git(["init", "-q"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "Test"])
        try "let timeout = 30\nrun()\n".write(to: root.appendingPathComponent("app.swift"),
                                              atomically: true, encoding: .utf8)
        git(["add", "-A"])
        git(["commit", "-qm", "first"])
        return root
    }

    @Test("an unstaged edit produces a diff with the change marked")
    func unstagedDiff() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "let timeout = 45\nrun()\n".write(to: root.appendingPathComponent("app.swift"),
                                              atomically: true, encoding: .utf8)

        let model = GitModel(root: root)
        await model.refresh()
        let change = try #require(model.changes.first { $0.path == "app.swift" })

        let diff = await model.diff(for: change, side: .unstaged)
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)
        let addition = try #require(diff.hunks.first?.lines.first { $0.kind == .addition })
        #expect(addition.text == "let timeout = 45")
        #expect(!addition.emphasis.isEmpty, "the changed digits should be marked")
    }

    /// A file can be staged AND modified. Each side has to answer for itself, or one button
    /// would be claiming to mean two different things.
    @Test("staged and unstaged are different diffs for the same file")
    func bothSides() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.swift")

        try "let timeout = 45\nrun()\n".write(to: file, atomically: true, encoding: .utf8)
        let stage = Process()
        stage.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        stage.arguments = ["-C", root.path, "add", "-A"]
        stage.standardOutput = Pipe(); try stage.run(); stage.waitUntilExit()
        try "let timeout = 60\nrun()\n".write(to: file, atomically: true, encoding: .utf8)

        let model = GitModel(root: root)
        await model.refresh()
        let change = try #require(model.changes.first { $0.path == "app.swift" })
        #expect(model.availableSides(for: change).count == 2)

        let staged = await model.diff(for: change, side: .staged)
        let unstaged = await model.diff(for: change, side: .unstaged)
        #expect(staged.hunks.first?.lines.contains { $0.text == "let timeout = 45" } == true)
        #expect(unstaged.hunks.first?.lines.contains { $0.text == "let timeout = 60" } == true)
        #expect(staged != unstaged)
    }

    /// git has never seen an untracked file, so `git diff` says nothing about it. Clicking a
    /// new file should still show its contents rather than an empty pane.
    @Test("an untracked file shows its contents as additions")
    func untrackedFile() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "brand new\nsecond line\n".write(to: root.appendingPathComponent("new.txt"),
                                             atomically: true, encoding: .utf8)

        let model = GitModel(root: root)
        await model.refresh()
        let change = try #require(model.changes.first { $0.path == "new.txt" })
        #expect(change.staged == .untracked)
        #expect(model.availableSides(for: change) == [.unstaged])

        let diff = await model.diff(for: change, side: .unstaged)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 0)
    }

    @Test("a file with nothing on the requested side reports empty, not an error")
    func emptySide() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "let timeout = 45\nrun()\n".write(to: root.appendingPathComponent("app.swift"),
                                              atomically: true, encoding: .utf8)
        let model = GitModel(root: root)
        await model.refresh()
        let change = try #require(model.changes.first)

        let staged = await model.diff(for: change, side: .staged)
        #expect(staged.isEmpty)
        #expect(!staged.isBinary)
    }
}

/// A `FileManager` that reports nothing executable — a Mac with no `gh` installed.
private final class NoFilesManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}

@Suite("Git worktrees")
@MainActor
struct GitWorktreeTests {

    @Test("the main worktree is the first, and locked and prunable ones say so")
    func flags() {
        let output = """
        worktree /Users/x/repo
        HEAD abc
        branch refs/heads/main

        worktree /Users/x/repo-kept
        HEAD def
        branch refs/heads/kept
        locked being used on the other machine

        worktree /Users/x/repo-gone
        HEAD 123
        detached
        prunable gitdir file points to non-existent location

        """
        let trees = GitModel.parseWorktrees(output, current: "/Users/x/repo")
        #expect(trees.map(\.isMain) == [true, false, false])
        #expect(trees.map(\.isLocked) == [false, true, false])
        #expect(trees.map(\.isPrunable) == [false, false, true])
        // Detached: no branch, so it is called by its folder.
        #expect(trees.map(\.label) == ["main", "kept", "repo-gone"])
    }

    /// Where an agent puts its worktrees. The repository's path prefixes the nested one's,
    /// and both were reported as current.
    @Test("a worktree nested in the repository is the current one, and the repository is not")
    func nested() {
        let output = """
        worktree /Users/x/repo
        branch refs/heads/main

        worktree /Users/x/repo/.claude/worktrees/fix
        branch refs/heads/fix

        """
        let inside = GitModel.parseWorktrees(output, current: "/Users/x/repo/.claude/worktrees/fix/Sources")
        #expect(inside.map(\.isCurrent) == [false, true])
        let outside = GitModel.parseWorktrees(output, current: "/Users/x/repo/Sources")
        #expect(outside.map(\.isCurrent) == [true, false])
    }

    @Test("a new worktree goes beside the repository, named for it and the branch")
    func path() {
        #expect(GitModel.worktreePath(forBranch: "login", mainWorktree: "/Users/x/repo")
                == "/Users/x/repo-login")
        #expect(GitModel.worktreePath(forBranch: "feature/login", mainWorktree: "/Users/x/repo/")
                == "/Users/x/repo-feature-login")
    }

    @Test("git's refusal is shown without its prefix")
    func reason() {
        #expect(GitModel.gitReason("Preparing worktree\nfatal: 'main' is already used by worktree at '/x'")
                == "'main' is already used by worktree at '/x'")
        #expect(GitModel.gitReason("") == "git could not do that.")
    }

    // MARK: Against a real repository

    private func git(_ root: URL, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path] + args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    /// A repository in a folder of its own, so the worktrees made beside it are cleaned up
    /// with it.
    private func makeRepo() throws -> (folder: URL, root: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-worktree-\(UUID().uuidString)")
        let root = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git(root, ["init", "-q", "-b", "main"])
        git(root, ["config", "user.email", "t@example.com"])
        git(root, ["config", "user.name", "Test"])
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(root, ["add", "-A"])
        git(root, ["commit", "-qm", "first"])
        return (folder, root)
    }

    @Test("a new branch gets a worktree beside the repository, and a model there reads it")
    func addNewBranch() async throws {
        let (folder, root) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = GitModel(root: root)
        await model.refresh()

        let urlMade = await model.addWorktree(branch: "feature/login")
        let url = try #require(urlMade)
        #expect(url.lastPathComponent == "repo-feature-login")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("a.txt").path))
        #expect(model.worktreeFailure == nil)
        #expect(model.worktrees.map(\.branch) == ["main", "feature/login"])
        #expect(model.worktrees.map(\.isCurrent) == [true, false])

        // The pane pointed at it: its branch, and it is the current one.
        let there = GitModel(root: url)
        await there.refresh()
        #expect(there.branch == "feature/login")
        #expect(there.currentWorktree?.branch == "feature/login")
        #expect(there.currentWorktree?.isMain == false)
        #expect(there.worktree(after: 1)?.branch == "main")
        #expect(there.worktree(after: -1)?.branch == "main")
    }

    @Test("an existing branch is checked out, not made again")
    func addExistingBranch() async throws {
        let (folder, root) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: folder) }
        git(root, ["branch", "old"])
        let model = GitModel(root: root)
        await model.refresh()
        let urlMade = await model.addWorktree(branch: "old")
        let url = try #require(urlMade)
        let there = GitModel(root: url)
        await there.refresh()
        #expect(there.branch == "old")
    }

    @Test("what git refuses is reported, and nothing is made")
    func addRefused() async throws {
        let (folder, root) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = GitModel(root: root)
        await model.refresh()

        // The branch the repository itself has checked out.
        #expect(await model.addWorktree(branch: "main") == nil)
        #expect(model.worktreeFailure?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("repo-main").path))

        #expect(await model.addWorktree(branch: "no good..name") == nil)
        #expect(model.worktreeFailure?.contains("not a name") == true)
        #expect(await model.addWorktree(branch: "--force") == nil)
        #expect(model.worktrees.count == 1)

        // A folder already in the way.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("repo-taken"),
                                                withIntermediateDirectories: true)
        #expect(await model.addWorktree(branch: "taken") == nil)
        #expect(model.worktreeFailure?.contains("already there") == true)
    }

    @Test("a clean worktree is removed and its branch stays; a dirty one and the main one are not")
    func remove() async throws {
        let (folder, root) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = GitModel(root: root)
        await model.refresh()
        let cleanMade = await model.addWorktree(branch: "clean")
        let clean = try #require(cleanMade)
        let dirtyMade = await model.addWorktree(branch: "dirty")
        let dirty = try #require(dirtyMade)
        try "edited\n".write(to: dirty.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let main = try #require(model.worktrees.first { $0.isMain })
        #expect(await model.removeWorktree(main) == false)
        #expect(FileManager.default.fileExists(atPath: root.path))

        let dirtyTree = try #require(model.worktrees.first { $0.branch == "dirty" })
        #expect(await model.removeWorktree(dirtyTree) == false)
        #expect(model.worktreeFailure?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: dirty.path))

        // Removed from a model that is IN the worktree being removed, as the pane is.
        let inside = GitModel(root: clean)
        await inside.refresh()
        let cleanTree = try #require(inside.currentWorktree)
        #expect(await inside.removeWorktree(cleanTree))
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        await model.refresh()
        #expect(model.worktrees.map(\.branch) == ["main", "dirty"])
        #expect(model.worktreeFailure != nil)   // the dirty refusal, still to be read
        let branches = await CommandProbe.run("/usr/bin/git", ["-C", root.path, "branch", "--list", "clean"])
        #expect(branches.contains("clean"))
    }
}
