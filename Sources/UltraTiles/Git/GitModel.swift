import Foundation

/// A repository's branch, its divergence from upstream, its worktrees, and what has changed.
///
/// Everything comes from `git status --porcelain=v2 --branch`, which is the only status
/// format git promises not to change — `--porcelain` (v1) and the human output are both
/// explicitly unstable, and parsing either is how a tile starts lying during a rebase.
@MainActor
@Observable
public final class GitModel {

    public enum State: String, Sendable {
        case unmodified, modified, added, deleted, renamed, copied, untracked, conflicted
    }

    public struct Change: Identifiable, Equatable, Sendable {
        public let path: String
        /// What the index has, and what the working tree has — git tracks these separately
        /// and collapsing them loses "staged, then edited again".
        public let staged: State
        public let unstaged: State
        public var id: String { path }
        public var isStaged: Bool { staged != .unmodified && staged != .untracked }
    }

    public struct Worktree: Identifiable, Equatable, Sendable {
        public let path: String
        public let branch: String?
        public let isCurrent: Bool
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    public private(set) var branch: String?
    public private(set) var upstream: String?
    public private(set) var ahead: Int = 0
    public private(set) var behind: Int = 0
    public private(set) var changes: [Change] = []
    public private(set) var worktrees: [Worktree] = []
    public private(set) var isRepository = false
    /// Set during a rebase, merge or cherry-pick. The tile must keep reporting accurately
    /// through these, which is exactly when a hand-rolled parser drifts.
    public private(set) var operation: String?
    public private(set) var isRefreshing = false

    private let root: URL
    public init(root: URL) { self.root = root }

    public var stagedCount: Int { changes.filter(\.isStaged).count }
    public var unstagedCount: Int { changes.filter { $0.unstaged != .unmodified }.count }

    // MARK: Refresh

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let status = await git(["status", "--porcelain=v2", "--branch", "-z"])
        guard !status.isEmpty else {
            isRepository = false
            branch = nil; changes = []; worktrees = []; ahead = 0; behind = 0
            return
        }
        isRepository = true
        let parsed = Self.parseStatus(status)
        branch = parsed.branch
        upstream = parsed.upstream
        ahead = parsed.ahead
        behind = parsed.behind
        changes = parsed.changes
        operation = await currentOperation()
        worktrees = Self.parseWorktrees(await git(["worktree", "list", "--porcelain"]),
                                        current: root.path)
    }

    private func git(_ arguments: [String]) async -> String {
        await CommandProbe.run("/usr/bin/git", ["-C", root.path] + arguments)
    }

    /// Which multi-step operation is in flight, if any. Read from the git directory rather
    /// than inferred from status, because status alone cannot tell a rebase from a merge.
    private func currentOperation() async -> String? {
        let gitDir = await git(["rev-parse", "--git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDir.isEmpty else { return nil }
        let base = gitDir.hasPrefix("/") ? URL(fileURLWithPath: gitDir)
                                         : root.appendingPathComponent(gitDir)
        let markers: [(String, String)] = [
            ("rebase-merge", "Rebasing"), ("rebase-apply", "Rebasing"),
            ("MERGE_HEAD", "Merging"), ("CHERRY_PICK_HEAD", "Cherry-picking"),
            ("REVERT_HEAD", "Reverting"), ("BISECT_LOG", "Bisecting"),
        ]
        for (file, label) in markers
        where FileManager.default.fileExists(atPath: base.appendingPathComponent(file).path) {
            return label
        }
        return nil
    }

    // MARK: Parsing

    struct Status: Equatable {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes: [Change] = []
    }

    /// porcelain=v2 with -z: NUL-separated records.
    ///   `# branch.head main`, `# branch.ab +2 -1`
    ///   `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`   ordinary change
    ///   `2 ...` rename/copy (its origin path follows as its own NUL-separated field)
    ///   `u ...` unmerged, `? <path>` untracked
    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let marker = record.first else { continue }
            switch marker {
            case "#":
                let fields = record.split(separator: " ").map(String.init)
                guard fields.count >= 2 else { continue }
                switch fields[0] {
                case "#" where fields.count >= 3 && fields[1] == "branch.head":
                    status.branch = fields[2] == "(detached)" ? nil : fields[2]
                case "#" where fields.count >= 3 && fields[1] == "branch.upstream":
                    status.upstream = fields[2]
                case "#" where fields.count >= 4 && fields[1] == "branch.ab":
                    status.ahead = abs(Int(fields[2]) ?? 0)
                    status.behind = abs(Int(fields[3]) ?? 0)
                default: continue
                }
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8).map(String.init)
                guard fields.count >= 9 else { continue }
                status.changes.append(change(xy: fields[1], path: fields[8]))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9).map(String.init)
                guard fields.count >= 10 else { continue }
                // A rename's origin path is the NEXT NUL-separated record; skip it so it is
                // never mistaken for a file of its own.
                if index < records.count { index += 1 }
                status.changes.append(change(xy: fields[1], path: fields[9]))
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10).map(String.init)
                guard let path = fields.last else { continue }
                status.changes.append(Change(path: path, staged: .conflicted, unstaged: .conflicted))
            case "?":
                let path = String(record.dropFirst(2))
                status.changes.append(Change(path: path, staged: .untracked, unstaged: .untracked))
            default: continue
            }
        }
        status.changes.sort { $0.path < $1.path }
        return status
    }

    private static func change(xy: String, path: String) -> Change {
        let characters = Array(xy)
        return Change(path: path,
                      staged: state(characters.first ?? "."),
                      unstaged: state(characters.count > 1 ? characters[1] : "."))
    }

    private static func state(_ character: Character) -> State {
        switch character {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .conflicted
        case "?": .untracked
        default: .unmodified
        }
    }

    /// `git worktree list --porcelain`: blocks of `worktree <path>` / `branch refs/heads/x`.
    static func parseWorktrees(_ output: String, current: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var branch: String?
        // Resolved, because git reports /private/var while Foundation hands us /var for the
        // same directory, and a plain string compare then says no worktree is current.
        let here = canonical(current)
        func flush() {
            guard let path else { return }
            let there = canonical(path)
            // The trailing slash is load-bearing: without it "/x/repo" prefixes
            // "/x/repo-feature" and a sibling worktree is reported as the current one.
            let isCurrent = here == there || here.hasPrefix(there + "/")
            result.append(Worktree(path: path, branch: branch, isCurrent: isCurrent))
            branch = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            } else if line.isEmpty {
                flush(); path = nil
            }
        }
        flush()
        return result
    }

    /// Symlinks resolved and the path standardised, so two spellings of one directory
    /// compare equal.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Actions — every one explicit, none automatic

    // MARK: Diffs

    /// The diff for one file on one side.
    ///
    /// `-U3` and `--no-color`: git colours its output for a terminal, and those escape
    /// sequences would be rendered as literal text here. An untracked file has no diff at
    /// all — git has never seen it — so it is compared against /dev/null, which is what
    /// makes clicking a new file show its contents rather than nothing.
    public func diff(for change: Change, side: DiffSide) async -> FileDiff {
        let raw: String
        if change.staged == .untracked {
            guard side == .unstaged else { return .empty(path: change.path, side: side) }
            raw = await git(["diff", "--no-color", "--no-index", "-U3",
                             "--", "/dev/null", change.path])
        } else {
            raw = await git(["diff", "--no-color", "-U3"] + side.gitArguments
                            + ["--", change.path])
        }
        return DiffParser.parse(raw, path: change.path, side: side)
    }

    /// Which sides actually have something to show, so the picker never offers an empty tab.
    public func availableSides(for change: Change) -> [DiffSide] {
        if change.staged == .untracked { return [.unstaged] }
        var sides: [DiffSide] = []
        if change.unstaged != .unmodified { sides.append(.unstaged) }
        if change.isStaged { sides.append(.staged) }
        return sides.isEmpty ? [.unstaged] : sides
    }

    public func stage(_ change: Change) async { _ = await git(["add", "--", change.path]) ; await refresh() }
    public func unstage(_ change: Change) async { _ = await git(["restore", "--staged", "--", change.path]); await refresh() }
    public func stageAll() async { _ = await git(["add", "-A"]); await refresh() }

    /// The one destructive verb, and the tile requires a confirmation before calling it.
    /// Nothing here ever runs a reset, a clean, or a force anything.
    public func discard(_ change: Change) async {
        if change.staged == .untracked {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent(change.path))
        } else {
            _ = await git(["restore", "--", change.path])
        }
        await refresh()
    }
}
