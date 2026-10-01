import Foundation
import Security

/// A vendor's own agent on this Mac — Claude Code, Codex — driven as a subprocess so a
/// chat can run on the user's subscription rather than a key.
///
/// This is the only way a subscription can be used from another app. Anthropic's terms
/// let a Claude plan be used only inside the unmodified Claude Code binary, signed in
/// through Anthropic's own flow; OpenAI opens a ChatGPT plan to third parties only through
/// Codex or to approved partners. So nothing here holds a token, and sign-in is the
/// engine's own: the app starts it and gets out of the way. Xcode and Notepad.exe reach
/// the same plans the same way.
public enum ChatEngine: String, Sendable, CaseIterable, Identifiable {
    case claudeCode
    case codex

    public var id: String { rawValue }

    /// The model name that means "whatever the engine would use": its own default, which
    /// the user may have set, rather than a name chosen here and stale by its next release.
    public static let defaultModel = "default"

    public var provider: ChatProviderID {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }

    public var title: String { provider.title }

    /// The plan the engine draws on, for a Settings row.
    public var planName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "ChatGPT"
        }
    }

    /// The binary's name on PATH.
    public var command: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    /// The vendor's own one-line install, for when the binary is not here.
    public var installCommand: String {
        switch self {
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        }
    }

    /// The binary, if it is on this Mac. Looked up once and remembered; `forgetLocations`
    /// after an install.
    public var executable: URL? { EngineLocator.shared.executable(for: self) }

    public static func forgetLocations() { EngineLocator.shared.forget() }

    // MARK: - Account

    /// Who is signed in, or nil when nobody is. Throws when the engine is not installed
    /// or cannot be asked.
    public func account() async throws -> EngineAccount? {
        switch self {
        case .claudeCode:
            guard let executable else { throw ChatError.notInstalled(provider) }
            let run = try await Subprocess.run(executable, arguments: ["auth", "status"])
            return Self.claudeAccount(from: run.stdout)
        case .codex:
            return try await CodexEngine.shared.account()
        }
    }

    /// `claude auth status` answers in JSON. Nil when it says nobody is signed in — or
    /// when it says nothing readable, which is the same thing to a Settings row.
    public static func claudeAccount(from json: String) -> EngineAccount? {
        guard let data = json.data(using: .utf8),
              let object = HTTPProviderSupport.object(data),
              object["loggedIn"] as? Bool == true else { return nil }
        return EngineAccount(email: object["email"] as? String,
                             plan: object["subscriptionType"] as? String)
    }

    /// Start the engine's own sign-in. What happens next is reported through the
    /// session's states; see `EngineSignIn`.
    public func beginSignIn() -> EngineSignIn {
        EngineSignIn(engine: self)
    }

    /// Forget the engine's login. The engine's own command, so it is gone the way the
    /// engine expects it to be.
    public func signOut() async throws {
        switch self {
        case .claudeCode:
            guard let executable else { throw ChatError.notInstalled(provider) }
            let run = try await Subprocess.run(executable, arguments: ["auth", "logout"])
            guard run.status == 0 else {
                throw ChatError.unavailable(Subprocess.lastLine(of: run.stderr + run.stdout)
                                            ?? "Sign-out did not complete.")
            }
        case .codex:
            _ = try await CodexEngine.shared.request("account/logout", [:])
        }
    }

    /// The page `claude auth login` says to visit, from the line it prints saying so.
    public static func loginURL(in line: String) -> URL? {
        guard let range = line.range(of: "https://") else { return nil }
        let rest = line[range.lowerBound...]
        let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        return URL(string: String(rest[..<end]))
    }

    /// When Claude Code last wrote its login to the keychain. A sign-in that completes
    /// moves this, which is how one is noticed even when the user was signed in before
    /// — `claude auth status` would say the same thing before and after.
    public static func claudeCredentialModified() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    // MARK: - Conversations

    /// A conversation as one prompt, for an engine that has lost its own record of it:
    /// what was said so far, then what is being asked now.
    public static func transcript(_ messages: [ChatMessage]) -> String {
        let spoken = messages.filter { !$0.text.isEmpty }
        guard let last = spoken.last else { return "" }
        let earlier = spoken.dropLast()
        guard !earlier.isEmpty else { return last.text }
        let lines = earlier.map { message in
            "\(message.role == .user ? "User" : "Assistant"): \(message.text)"
        }
        return "Earlier in this conversation:\n\n" + lines.joined(separator: "\n\n")
            + "\n\nNow the user says:\n\n" + last.text
    }

    /// An engine's tool call in a few words, for the row under an answer. Nil for a name
    /// that is not an engine's.
    public static func summary(of call: ChatToolCall) -> String? {
        switch call.name {
        case "Read":
            return "Read \(shortPath(call.string("file_path") ?? ""))"
        case "Glob":
            return "Find \(call.string("pattern") ?? "")"
        case "Grep":
            return "Search for “\(call.string("pattern") ?? "")”"
        case "command", "Bash":
            return "Run \(call.string("command") ?? "")"
        case "Edit", "MultiEdit", "NotebookEdit":
            return "Edit \(shortPath(call.string("file_path") ?? call.string("notebook_path") ?? ""))"
        case "Write":
            return "Write \(shortPath(call.string("file_path") ?? ""))"
        case "edit":
            let paths = (call.argumentValues["paths"] as? [String] ?? []).map(shortPath)
            return "Edit \(paths.joined(separator: ", "))"
        default:
            return nil
        }
    }

    /// The files a Claude Code call changes, counted from its arguments — the only place
    /// an edit is spelled out, since the result is a sentence. Nil for a call that is not
    /// a change. A `Write` over a file that is there is counted against what it held; one
    /// where there was none is an add. A command is read for the files it removes or
    /// makes (`CommandChanges`); one that does neither is nil, a plain row.
    public static func fileChanges(of call: ChatToolCall, in directory: URL? = nil) -> [ChatFileChange]? {
        let path = call.string("file_path") ?? call.string("notebook_path") ?? ""
        switch call.name {
        case "Edit":
            let counts = ChatFileChange.counts(from: call.string("old_string") ?? "",
                                               to: call.string("new_string") ?? "")
            return [ChatFileChange(path: path, additions: counts.additions, deletions: counts.deletions)]
        case "MultiEdit":
            let edits = call.argumentValues["edits"] as? [[String: Any]] ?? []
            var change = ChatFileChange(path: path)
            for edit in edits {
                let counts = ChatFileChange.counts(from: edit["old_string"] as? String ?? "",
                                                   to: edit["new_string"] as? String ?? "")
                change.additions += counts.additions
                change.deletions += counts.deletions
            }
            return [change]
        case "Write":
            let content = call.string("content") ?? ""
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : (directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return [ChatFileChange(path: path, additions: ChatFileChange.lineCount(content), kind: .added)]
            }
            guard let old = ChatFileChange.text(ofFileAt: url) else {
                return [ChatFileChange(path: path, additions: ChatFileChange.lineCount(content))]
            }
            let counts = ChatFileChange.counts(from: old, to: content)
            return [ChatFileChange(path: path, additions: counts.additions, deletions: counts.deletions)]
        case "NotebookEdit":
            return [ChatFileChange(path: path, additions: ChatFileChange.lineCount(call.string("new_source") ?? ""))]
        case "Bash", "command":
            let changes = CommandChanges.changes(in: call.string("command") ?? "", under: directory)
            return changes.isEmpty ? nil : changes
        default:
            return nil
        }
    }

    /// The last two components of an absolute path: enough to know which file, without
    /// the project's whole path in front of every row.
    static func shortPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

/// Who an engine is signed in as.
public struct EngineAccount: Sendable, Equatable {
    public var email: String?
    public var plan: String?

    public init(email: String? = nil, plan: String? = nil) {
        self.email = email
        self.plan = plan
    }

    /// "bakens@gmail.com · Max", or what there is of it.
    public var description: String {
        let plan = plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return [email, plan].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Finding the binaries

/// Where the engines are. A GUI app's PATH is the bare system one, so the usual homes of
/// a developer's tools are looked in as well, and the login shell is asked last.
final class EngineLocator: @unchecked Sendable {
    static let shared = EngineLocator()

    private let lock = NSLock()
    private var cache: [ChatEngine: URL?] = [:]

    func executable(for engine: ChatEngine) -> URL? {
        lock.lock()
        if let cached = cache[engine] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let found = Self.find(engine.command)
        lock.lock()
        cache[engine] = found
        lock.unlock()
        return found
    }

    func forget() {
        lock.lock()
        cache = [:]
        lock.unlock()
    }

    static func find(_ command: String) -> URL? {
        let manager = FileManager.default
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(command)
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // The login shell knows paths set in .zprofile that the app was not started with.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").last.map(String.init),
              path.hasPrefix("/"), manager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        directories += [
            home.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".bun/bin"),
            home.appendingPathComponent(".cargo/bin"),
        ]
        // nvm keeps one bin per Node version; the newest is the one in use, most often.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for version in versions.sorted().reversed() {
                directories.append(nvm.appendingPathComponent(version).appendingPathComponent("bin"))
            }
        }
        return directories
    }

    /// A PATH for the engine itself, so what it launches — node, git, ripgrep — is found
    /// as it would be from the user's own shell.
    static var path: String {
        var seen = Set<String>()
        return searchDirectories.map(\.path).filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }
}

// MARK: - What the engines did

/// A line per thing an engine did — started, answered, stopped, failed — in
/// `~/Library/Logs/Ultra/engines.log`, for the day a chat says nothing and the question is
/// why. Short lines, no prompts and no answers: what happened, not what was said.
public enum EngineLog {
    public static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ultra/engines.log")
    private static let lock = NSLock()
    /// Kept small: a log nobody reads should not grow without bound.
    static let maxBytes = 512_000

    public static func note(_ engine: ChatEngine, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(engine.command): \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
            try? manager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - Running things

enum Subprocess {
    /// How long a turn may go without the engine saying anything before it is given up
    /// on. Long enough for a build the engine is waiting on; short enough that a chat
    /// does not wait forever on an engine that has quietly died.
    static let turnInactivityLimit: Duration = .seconds(600)

    struct Outcome: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// The environment an engine is started with: the app's, with a fuller PATH, and
    /// without the marks of the session Ultra itself may have been launched from.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = EngineLocator.path
        // Claude Code refuses to start inside another Claude Code session.
        environment.removeValue(forKey: "CLAUDECODE")
        return environment
    }

    /// Run to the end, collecting what it printed.
    static func run(_ executable: URL, arguments: [String], input: String? = nil,
                    currentDirectory: URL? = nil) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment()
        process.currentDirectoryURL = currentDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        async let out = read(stdout.fileHandleForReading)
        async let err = read(stderr.fileHandleForReading)
        let (outText, errText) = await (out, err)
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, stdout: outText, stderr: errText)
    }

    /// Everything a handle has to give, off the cooperative pool: the read blocks.
    static func read(_ handle: FileHandle) async -> String {
        await Task.detached {
            String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }.value
    }

    /// The last thing printed that says anything, for an error message.
    static func lastLine(of text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// A running process, reachable from a stream's termination handler. The handler is
/// `Sendable` and `Process` is not; the lock is what makes the pairing honest.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func hold(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

// MARK: - Signing in

/// Where a sign-in is, in words the row can show.
public enum EngineSignInState: Sendable, Equatable {
    case starting
    /// The vendor's page is open; waiting for the user to approve there. The URL is for
    /// opening it again, and nil until the engine has said what it is.
    case waitingForBrowser(URL?)
    /// Approved, or so it seems; the engine is being asked what it now knows.
    case verifying
    case signedIn(EngineAccount)
    case failed(String)
    case cancelled

    /// Whether this is the end of the session.
    public var isTerminal: Bool {
        switch self {
        case .signedIn, .failed, .cancelled: true
        default: false
        }
    }
}

/// One sign-in, from the button to the account. The states arrive as they happen; a
/// terminal one ends the stream.
///
/// Claude Code's login is a process: it opens the browser, runs a callback server and
/// prints "Login successful" when the browser comes back, or waits for a code pasted at
/// its prompt when it cannot. Both are handled — the prompt's stdin is kept, `submit` writes
/// to it — and both are checked rather than believed: the keychain entry the login writes
/// is watched, so approval is noticed even if the process is slow to say so, and the
/// account is read back before anything is called signed in. Codex's login is a request to
/// its server, which opens nothing: the URL comes back for the app to open, and completion
/// is a notification, confirmed the same way.
public actor EngineSignIn {
    public nonisolated let engine: ChatEngine
    public nonisolated let states: AsyncStream<EngineSignInState>
    private nonisolated let feed: AsyncStream<EngineSignInState>.Continuation

    /// How long an approval is waited for. A browser tab left open for longer than this
    /// is one the user has forgotten.
    static let timeout: Duration = .seconds(600)
    static let pollInterval: Duration = .milliseconds(1500)

    private var task: Task<Void, Never>?
    private let process = ProcessBox()
    private var input: FileHandle?
    private var codexLoginID: String?
    private var ended = false

    init(engine: ChatEngine) {
        self.engine = engine
        (states, feed) = AsyncStream<EngineSignInState>.makeStream()
        Task { await self.start() }
    }

    private func start() {
        task = Task { [weak self] in
            guard let self else { return }
            switch engine {
            case .claudeCode: await runClaude()
            case .codex: await runCodex()
            }
        }
    }

    private func report(_ state: EngineSignInState) {
        guard !ended else { return }
        feed.yield(state)
        if state.isTerminal {
            ended = true
            feed.finish()
        }
    }

    /// Stop waiting. The engine's own login is stopped too, so it is not left running.
    public func cancel() async {
        guard !ended else { return }
        task?.cancel()
        process.terminate()
        if engine == .codex, let codexLoginID {
            _ = try? await CodexEngine.shared.request("account/login/cancel", ["loginId": codexLoginID])
        }
        report(.cancelled)
    }

    /// The code the browser showed, for Claude Code's prompt. Nothing to Codex.
    public func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let input else { return }
        try? input.write(contentsOf: Data((trimmed + "\n").utf8))
    }

    // MARK: Claude Code

    private func runClaude() async {
        guard let executable = engine.executable else {
            report(.failed(ChatError.notInstalled(engine.provider).errorDescription ?? ""))
            return
        }
        report(.starting)
        let before = ChatEngine.claudeCredentialModified()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "login"]
        process.environment = Subprocess.environment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            report(.failed("Could not start Claude Code: \(error.localizedDescription)"))
            return
        }
        self.process.hold(process)
        input = stdin.fileHandleForWriting

        // Three things can say it is done: the process, by printing so and exiting; the
        // keychain, by changing; or the clock, by running out. Whichever is first.
        let outcome = await withTaskGroup(of: ClaudeOutcome.self) { group -> ClaudeOutcome in
            group.addTask { [weak self] in
                var said = false
                do {
                    for try await line in stdout.fileHandleForReading.engineLines() {
                        if let url = ChatEngine.loginURL(in: line) { await self?.report(.waitingForBrowser(url)) }
                        if line.contains("Login successful") { said = true }
                    }
                } catch {}
                while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return said || process.terminationStatus == 0
                    ? .finished
                    : .exited(Subprocess.lastLine(of: err) ?? "Claude Code stopped without signing in.")
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    if let now = ChatEngine.claudeCredentialModified(), now > (before ?? .distantPast) {
                        return .keychainChanged
                    }
                }
                return .cancelled
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return Task.isCancelled ? .cancelled : .timedOut
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        if Task.isCancelled { return }
        switch outcome {
        case .finished, .keychainChanged:
            process.terminate()
            await verify()
        case .exited(let reason):
            report(.failed(reason))
        case .timedOut:
            process.terminate()
            report(.failed("No approval arrived from the browser. Try again."))
        case .cancelled:
            break
        }
    }

    private enum ClaudeOutcome: Sendable {
        case finished, keychainChanged, timedOut, cancelled
        case exited(String)
    }

    // MARK: Codex

    private func runCodex() async {
        guard engine.executable != nil else {
            report(.failed(ChatError.notInstalled(engine.provider).errorDescription ?? ""))
            return
        }
        report(.starting)
        let server = CodexEngine.shared
        let (completions, completed) = AsyncStream<Data>.makeStream()
        let listener = await server.subscribe { notification in
            if notification.method == "account/login/completed" { completed.yield(notification.params) }
        }
        defer { Task { await server.unsubscribe(listener) } }
        let started: [String: Any]
        do {
            started = try await server.request("account/login/start", ["type": "chatgpt"])
        } catch {
            report(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        guard let loginID = started["loginId"] as? String else {
            report(.failed("Codex did not start a sign-in."))
            return
        }
        codexLoginID = loginID
        report(.waitingForBrowser((started["authUrl"] as? String).flatMap(URL.init(string:))))

        let outcome = await withTaskGroup(of: CodexOutcome.self) { group -> CodexOutcome in
            group.addTask {
                for await params in completions {
                    guard let object = HTTPProviderSupport.object(params),
                          (object["loginId"] as? String ?? loginID) == loginID else { continue }
                    return object["success"] as? Bool == true
                        ? .completed
                        : .failed(object["error"] as? String ?? "Codex did not complete the sign-in.")
                }
                return .cancelled
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return Task.isCancelled ? .cancelled : .timedOut
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        if Task.isCancelled { return }
        switch outcome {
        case .completed:
            await verify()
        case .failed(let reason):
            report(.failed(reason))
        case .timedOut:
            _ = try? await server.request("account/login/cancel", ["loginId": loginID])
            report(.failed("No approval arrived from the browser. Try again."))
        case .cancelled:
            break
        }
    }

    private enum CodexOutcome: Sendable {
        case completed, timedOut, cancelled
        case failed(String)
    }

    // MARK: Both

    /// The engine said it is done; ask it who it is now. Said signed in only once it
    /// answers with an account.
    private func verify() async {
        report(.verifying)
        // The engine may take a moment to write what it has just been given.
        for attempt in 0..<5 {
            if let account = try? await engine.account() {
                report(.signedIn(account))
                return
            }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        report(.failed("The browser approved, but \(engine.title) still reports nobody signed in."))
    }
}

// MARK: - Reading an engine

extension FileHandle {
    /// The lines a process writes, as they arrive.
    ///
    /// NOT `bytes.lines`. Foundation reads those on one serial queue shared by every
    /// `FileHandle.bytes` in the process, and a read on a pipe blocks until something is
    /// written to it. The Codex server's pipe is open for the life of the app and quiet
    /// between turns, so its read sat on that queue for good, and every Claude Code
    /// read queued behind it was starved: an answer that trickled through only when Codex
    /// happened to say something. This reads through `readabilityHandler`, which calls
    /// back on a pool thread only when there is something to read, or EOF.
    func engineLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let splitter = LineBuffer()
            readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    if let last = splitter.finish() { continuation.yield(last) }
                    continuation.finish()
                    return
                }
                for line in splitter.feed(data) { continuation.yield(line) }
            }
            continuation.onTermination = { [self] _ in readabilityHandler = nil }
        }
    }
}

/// A `LineSplitter` behind a lock, for a handler that may be called from any thread.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        for byte in data {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        return lines
    }

    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return splitter.finish()
    }
}
