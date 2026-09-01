import Foundation

/// Starting a project that does not exist yet: an empty folder, or a clone.
///
/// The two are one type because they end in the same place — a directory on disk that the
/// window can open as a session — and because everything around them is shared: where it
/// goes, what it may be called, and what to say when the answer is no. Splitting them gave
/// two validators that disagreed about whether "my repo" was a usable folder name.
///
/// No UI, no windows, no `LayoutStore`. That is what makes the rules testable rather than
/// something you find out about by clicking through a sheet.
public enum NewProject {

    // MARK: - What a project may be called

    /// Why a project cannot be created, in the words the sheet shows.
    ///
    /// One case per thing that can actually be wrong, rather than a bool: "Create" being
    /// dimmed with no reason given is the failure mode this replaces, and a user staring at
    /// a disabled button has no way to find out that the name they typed already exists.
    public enum Problem: Equatable, Sendable {
        case noName
        case noRepository
        case separatorInName
        case reservedName
        case parentMissing
        case parentNotADirectory
        case alreadyExists

        public var message: String {
            switch self {
            case .noName: "Give the folder a name."
            case .noRepository: "Enter a repository URL."
            // Said plainly rather than silently creating the intermediates: "a/b" as a
            // project name is far more often a slip than a request for a nested folder.
            case .separatorInName: "A folder name cannot contain “/”."
            case .reservedName: "“.” and “..” are not folder names."
            case .parentMissing: "That location no longer exists."
            case .parentNotADirectory: "That location is a file, not a folder."
            case .alreadyExists: "Something with that name is already there."
            }
        }
    }

    /// What is wrong with putting a folder of this name in this place, or nil.
    ///
    /// The parent is checked as well as the name, because the two ways this fails in
    /// practice are a typo and a location that has been moved since the sheet opened.
    public static func problem(name: String,
                               in parent: URL,
                               fileManager: FileManager = .default) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .noName }
        if trimmed.contains("/") { return .separatorInName }
        if trimmed == "." || trimmed == ".." { return .reservedName }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) else {
            return .parentMissing
        }
        guard isDirectory.boolValue else { return .parentNotADirectory }
        // `fileExists` rather than a directory check: a FILE called `my-project` sitting
        // there stops the folder being created just as surely as a folder does.
        if fileManager.fileExists(atPath: destination(name: trimmed, in: parent).path) {
            return .alreadyExists
        }
        return nil
    }

    /// What is wrong with this repository URL, or nil.
    ///
    /// Deliberately only "is there one". Everything else about a git URL — whether the host
    /// resolves, whether the path is a repository, whether this user may read it — is a
    /// question only `git clone` can answer, and a client-side pattern that guesses at it
    /// rejects the working URLs that do not look like the common ones: `ssh://`, a bare
    /// `host:path`, a local directory, a `file://`, an internal forge on a port.
    public static func problem(repository: String) -> Problem? {
        repository.trimmingCharacters(in: .whitespaces).isEmpty ? .noRepository : nil
    }

    public static func destination(name: String, in parent: URL) -> URL {
        parent.appendingPathComponent(name.trimmingCharacters(in: .whitespaces),
                                      isDirectory: true)
    }

    // MARK: - Naming a clone

    /// The folder `git clone` would choose for this URL, so the sheet can offer it before
    /// the user has typed anything and get out of the way when they have.
    ///
    /// Matches git's own rule — the last path component, minus a `.git` suffix — across the
    /// spellings people actually paste: an https URL, an `scp`-style `git@host:owner/repo`,
    /// a trailing slash, a local path. Empty when there is nothing to go on, which is the
    /// sheet's cue to keep asking rather than to invent a name.
    public static func folderName(forRepository url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)
        // A query or fragment is not part of the name — a URL copied out of a browser's
        // address bar routinely carries one.
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[text.startIndex..<cut])
        }
        while text.hasSuffix("/") { text.removeLast() }
        // Both separators, because `git@github.com:owner/repo` uses one of each and the
        // interesting part is always after the LAST of either.
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    // MARK: - Making one

    public enum Failure: Error, Equatable, Sendable {
        /// The name or the location was refused before anything was written.
        case refused(Problem)
        /// The filesystem said no.
        case notCreated(String)
        /// `git` ran and failed. Carries what it printed, because "clone failed" on its own
        /// tells the user nothing they can act on — the message is always the useful part.
        case gitFailed(status: Int32, output: String)
        /// `git` is not installed, or not where it is looked for.
        case gitMissing
        case cancelled
    }

    /// Where git lives.
    ///
    /// Looked for by path rather than run by name, for the reason `GitModel.ghPath` gives:
    /// a bundled app inherits launchd's `PATH`, not a login shell's. `/usr/bin/git` is the
    /// Command Line Tools shim and is present on any Mac that can build anything, with the
    /// two Homebrew prefixes behind it for a machine where the shim has been removed.
    public static func gitPath(fileManager: FileManager = .default) -> String? {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Create an empty project folder, optionally as a git repository.
    ///
    /// `withIntermediateDirectories: false` on purpose. The name has already been refused if
    /// it contains a separator, so there are no intermediates to make — and the flag also
    /// suppresses the "already exists" error, which is the one error here worth having.
    @discardableResult
    public static func createFolder(named name: String,
                                    in parent: URL,
                                    initializingGit: Bool,
                                    fileManager: FileManager = .default) throws -> URL {
        if let problem = problem(name: name, in: parent, fileManager: fileManager) {
            throw Failure.refused(problem)
        }
        let url = destination(name: name, in: parent)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw Failure.notCreated(error.localizedDescription)
        }
        guard initializingGit else { return url }
        guard let git = gitPath(fileManager: fileManager) else { throw Failure.gitMissing }
        // The folder is NOT removed when `git init` fails. It exists, it is empty, it is
        // what the user asked for — and deleting a directory because a second, optional
        // step did not work is a surprising way to lose one.
        let result = Self.run(git, ["init", "--quiet", url.path])
        guard result.status == 0 else {
            throw Failure.gitFailed(status: result.status, output: result.output)
        }
        return url
    }

    /// Clone a repository into `parent/name`.
    ///
    /// Cancellable, and it has to be: a clone of a large repository over a slow link is the
    /// one thing this app does that can take minutes, and a modal sheet with no way out of
    /// it is a modal sheet the user force-quits.
    public static func clone(repository: String,
                             named name: String,
                             in parent: URL,
                             fileManager: FileManager = .default) async -> Result<URL, Failure> {
        if let problem = problem(repository: repository) { return .failure(.refused(problem)) }
        if let problem = problem(name: name, in: parent, fileManager: fileManager) {
            return .failure(.refused(problem))
        }
        guard let git = gitPath(fileManager: fileManager) else { return .failure(.gitMissing) }
        let url = destination(name: name, in: parent)

        let process = Process()
        let result: (status: Int32, output: String)
        do {
            result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: Self.run(
                            git,
                            ["clone", "--progress", "--",
                             repository.trimmingCharacters(in: .whitespaces), url.path],
                            process: process))
                    }
                }
            } onCancel: {
                // `terminate` rather than letting it finish and throwing the result away: a
                // cancelled clone that keeps running keeps writing into a folder the user
                // has been told will not exist.
                process.terminate()
            }
        } catch {
            return .failure(.cancelled)
        }
        if Task.isCancelled { return .failure(.cancelled) }
        guard result.status == 0 else {
            // A failed clone leaves a partial directory behind. Git removes it itself when
            // it fails cleanly and does not when it is killed, so this is belt and braces —
            // and it matters, because the leftover is exactly what would make a retry with
            // the same name report "already there".
            try? fileManager.removeItem(at: url)
            return .failure(.gitFailed(status: result.status, output: result.output))
        }
        return .success(url)
    }

    // MARK: - Running git

    /// stdout and stderr TOGETHER, and the exit status.
    ///
    /// `CommandProbe` in UltraTiles would have been the obvious thing to reuse and it is
    /// wrong for this: it discards stderr, returns no status, and enforces a four-second
    /// deadline. Git says everything interesting — progress and every error — on stderr, a
    /// non-zero status is the whole question being asked, and four seconds is not a clone.
    private static func run(_ launchPath: String,
                            _ arguments: [String],
                            process: Process = Process()) -> (status: Int32, output: String) {
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Fail rather than HANG. A private https remote asks for a username on the terminal
        // it thinks it has, and a `Process` with a pipe for stdin gives it one that never
        // answers — so the clone would sit there forever with a spinner and no error. With
        // prompting off, git exits and says it needs credentials, which the sheet can show.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        environment["SSH_ASKPASS"] = ""
        // Batch mode does the same job for ssh remotes: no host-key question, no passphrase
        // prompt, just a failure the user can read.
        environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Nothing to say, and closed, so anything that asks reaches EOF rather than waiting.
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return (-1, "\(error.localizedDescription)") }

        // Read while it runs. Waiting first deadlocks the moment git writes more than a pipe
        // buffer of progress, which for any repository worth cloning is immediately.
        var data = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
