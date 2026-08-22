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
