import Foundation

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

    /// Start the engine's own sign-in and wait for it to end. Claude Code opens the
    /// browser itself; Codex hands back a URL, which `openURL` is asked to open.
    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        switch self {
        case .claudeCode:
            guard let executable else { throw ChatError.notInstalled(provider) }
            let run = try await Subprocess.run(executable, arguments: ["auth", "login"])
            guard run.status == 0 else {
                throw ChatError.unavailable(Subprocess.lastLine(of: run.stderr + run.stdout)
                                            ?? "Sign-in did not complete.")
            }
        case .codex:
            try await CodexEngine.shared.signIn(openURL: openURL)
        }
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
        case "command":
            return "Run \(call.string("command") ?? "")"
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

// MARK: - Running things

enum Subprocess {
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
