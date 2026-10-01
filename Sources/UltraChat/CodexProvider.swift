import Foundation

/// ChatGPT, through Codex's app server.
///
/// `codex app-server` is the interface OpenAI built for other products to embed Codex —
/// JSON-RPC over stdio, with the ChatGPT sign-in inside it. One server is kept for the
/// whole app (`CodexEngine`), since it starts a few MCP servers of its own and takes a
/// second to come up. A conversation is a Codex thread: the first turn starts one and the
/// rest resume it. The sandbox is read-only and nothing asks for approval, so the chat can
/// look at the project and run `git log`, and cannot change a file.
public struct CodexProvider: ChatProvider {
    public let id = ChatProviderID.codex

    public init() {}

    // MARK: - Stream

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let engine = CodexEngine.shared
                var listener: UUID?
                var threadID: String?
                var turnID: String?
                do {
                    guard ChatEngine.codex.executable != nil else { throw ChatError.notInstalled(id) }
                    guard try await engine.account() != nil else { throw ChatError.notSignedIn(id) }

                    let thread = try await Self.openThread(for: request, on: engine)
                    threadID = thread.id
                    if thread.isNew { continuation.yield(.session(thread.id)) }
                    let prompt = thread.isNew && request.session != nil
                        ? ChatEngine.transcript(request.messages)
                        : request.messages.last?.text ?? ""

                    // Listening before asking, so no event of the turn is missed.
                    let (notifications, feed) = AsyncStream<CodexEngine.Notification>.makeStream()
                    listener = await engine.subscribe { feed.yield($0) }

                    var turn: [String: Any] = [
                        "threadId": thread.id,
                        "input": [["type": "text", "text": prompt, "text_elements": []]],
                    ]
                    if request.model != ChatEngine.defaultModel { turn["model"] = request.model }
                    let started = try await engine.request("turn/start", turn)
                    turnID = (started["turn"] as? [String: Any])?["id"] as? String

                    var state = TurnState()
                    for await notification in notifications {
                        guard let params = HTTPProviderSupport.object(notification.params),
                              params["threadId"] as? String == thread.id else { continue }
                        for event in try Self.handle(method: notification.method, params: params, state: &state) {
                            continuation.yield(event)
                        }
                        if state.finished { break }
                    }
                    if let listener { await engine.unsubscribe(listener) }
                    if Task.isCancelled, let threadID, let turnID {
                        // Stopped from the pane: tell Codex, or it keeps working unseen.
                        _ = try? await engine.request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
                    }
                    continuation.finish()
                } catch {
                    if let listener { await engine.unsubscribe(listener) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct Thread {
        var id: String
        var isNew: Bool
    }

    /// The conversation's thread: resumed if Codex still has it, else started. A thread
    /// is started where the project is, and told what the chat is for.
    static func openThread(for request: ChatRequest, on engine: CodexEngine) async throws -> Thread {
        var settings: [String: Any] = ["approvalPolicy": "never", "sandbox": "read-only"]
        if let cwd = request.workingDirectory?.path { settings["cwd"] = cwd }
        if let session = request.session {
            var resume = settings
            resume["threadId"] = session
            if let response = try? await engine.request("thread/resume", resume),
               let id = (response["thread"] as? [String: Any])?["id"] as? String {
                return Thread(id: id, isNew: false)
            }
        }
        var start = settings
        if let system = request.system, !system.isEmpty { start["developerInstructions"] = system }
        if request.model != ChatEngine.defaultModel { start["model"] = request.model }
        let response = try await engine.request("thread/start", start)
        guard let id = (response["thread"] as? [String: Any])?["id"] as? String else {
            throw ChatError.malformed("thread/start returned no thread")
        }
        return Thread(id: id, isNew: true)
    }

    // MARK: - Notifications

    /// What has been learned about the turn so far.
    struct TurnState {
        var finished = false
        /// Text already shown, per message item: the finished item carries the whole
        /// text, and only what was not streamed is new.
        var shown: [String: String] = [:]
        var inputTokens: Int?
        var outputTokens: Int?
    }

    /// One notification as chat events. Public so the mapping is testable against a
    /// recorded exchange.
    public static func handle(method: String, params: [String: Any]) throws -> [ChatEvent] {
        var state = TurnState()
        return try handle(method: method, params: params, state: &state)
    }

    static func handle(method: String, params: [String: Any], state: inout TurnState) throws -> [ChatEvent] {
        switch method {
        case "item/agentMessage/delta":
            guard let item = params["itemId"] as? String,
                  let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            state.shown[item, default: ""] += delta
            return [.text(delta)]

        case "item/started":
            guard let item = params["item"] as? [String: Any],
                  let id = item["id"] as? String else { return [] }
            switch item["type"] as? String {
            case "commandExecution":
                let arguments = ["command": item["command"] as? String ?? ""]
                return [.toolCall(ChatToolCall(id: id, name: "command", arguments: json(arguments)))]
            case "mcpToolCall", "dynamicToolCall":
                let name = item["tool"] as? String ?? "tool"
                return [.toolCall(ChatToolCall(id: id, name: name, arguments: json(item["arguments"] ?? [:])))]
            default:
                return []
            }

        case "item/completed":
            guard let item = params["item"] as? [String: Any],
                  let id = item["id"] as? String else { return [] }
            switch item["type"] as? String {
            case "agentMessage":
                let whole = item["text"] as? String ?? ""
                let shown = state.shown[id] ?? ""
                state.shown[id] = whole
                guard whole.count > shown.count else { return [] }
                let rest = whole.hasPrefix(shown) ? String(whole.dropFirst(shown.count)) : whole
                return rest.isEmpty ? [] : [.text(rest)]
            case "commandExecution":
                let output = item["aggregatedOutput"] as? String ?? ""
                let status = item["status"] as? String ?? ""
                let result = output.isEmpty ? status : output
                return [.toolResult(id: id, result: ClaudeCodeProvider.resultText(result))]
            case "mcpToolCall", "dynamicToolCall":
                if let error = item["error"] as? [String: Any], let message = error["message"] as? String {
                    return [.toolResult(id: id, result: message)]
                }
                let result = item["result"] ?? item["contentItems"] ?? ""
                let text = result as? String ?? json(result)
                return [.toolResult(id: id, result: ClaudeCodeProvider.resultText(text))]
            default:
                return []
            }

        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any],
               let last = usage["last"] as? [String: Any] {
                state.inputTokens = last["inputTokens"] as? Int
                state.outputTokens = last["outputTokens"] as? Int
            }
            return []

        case "turn/completed":
            state.finished = true
            let turn = params["turn"] as? [String: Any]
            switch turn?["status"] as? String {
            case "failed":
                let error = turn?["error"] as? [String: Any]
                throw ChatError.http(status: 0, message: error?["message"] as? String ?? "Codex reported an error.")
            case "interrupted":
                return [.finished(ChatFinish(reason: .other, detail: "interrupted",
                                             inputTokens: state.inputTokens, outputTokens: state.outputTokens))]
            default:
                return [.finished(ChatFinish(reason: .complete, inputTokens: state.inputTokens,
                                             outputTokens: state.outputTokens))]
            }

        case "error":
            // A retry is Codex's business; only an error it gives up on ends the turn.
            guard params["willRetry"] as? Bool != true,
                  let error = params["error"] as? [String: Any],
                  let message = error["message"] as? String else { return [] }
            state.finished = true
            throw ChatError.http(status: 0, message: message)

        default:
            return []
        }
    }

    static func json(_ object: Any) -> String {
        (try? HTTPProviderSupport.json(object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - Models

    public func models() async throws -> [String] {
        guard ChatEngine.codex.executable != nil else { throw ChatError.notInstalled(id) }
        let response = try await CodexEngine.shared.request("model/list", [:])
        return Self.parseModels(response)
    }

    /// The engine's default first — named as such, so the row in the picker is the one
    /// a fresh chat is on — then every model the picker would show.
    public static func parseModels(_ response: [String: Any]) -> [String] {
        let list = (response["data"] as? [[String: Any]] ?? [])
            .filter { $0["hidden"] as? Bool != true }
        return [ChatEngine.defaultModel] + list.compactMap { $0["id"] as? String }
    }
}

// MARK: - The server

/// One `codex app-server` for the app: started when first needed, restarted if it dies,
/// shared by every Codex conversation. JSON-RPC 2.0, a line per message.
actor CodexEngine {
    static let shared = CodexEngine()

    /// A server-to-client message that is not a reply: an event of a thread, or of the
    /// account. The params are left as JSON for the listener to read.
    struct Notification: Sendable {
        var method: String
        var params: Data
    }

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var handshake: Task<Void, Error>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var listeners: [UUID: @Sendable (Notification) -> Void] = [:]

    // MARK: Requests

    /// Ask, and get the result as the API shaped it. A JSON-RPC error is thrown as the
    /// message the server gave. Not isolated: only the JSON bytes cross into the actor,
    /// and the dictionaries at either end stay with the caller.
    nonisolated func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try HTTPProviderSupport.json(params)
        let result = try await send(method, params: data)
        return HTTPProviderSupport.object(result) ?? [:]
    }

    private func send(_ method: String, params: Data) async throws -> Data {
        try await ready()
        return try await sendRaw(method, params: params)
    }

    private func sendRaw(_ method: String, params: Data) async throws -> Data {
        let id = nextID
        nextID += 1
        var line = Data("{\"id\":\(id),\"method\":\"\(method)\",\"params\":".utf8)
        line += params
        line += Data("}\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: ChatError.unavailable("Codex is not answering."))
            }
        }
    }

    private func notify(_ method: String, params: Data) throws {
        var line = Data("{\"method\":\"\(method)\",\"params\":".utf8)
        line += params
        line += Data("}\n".utf8)
        try input?.write(contentsOf: line)
    }

    // MARK: Listening

    func subscribe(_ handler: @escaping @Sendable (Notification) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: Account

    /// Who is signed in, or nil when nobody is.
    func account() async throws -> EngineAccount? {
        let response = try await request("account/read", [:])
        guard let account = response["account"] as? [String: Any] else { return nil }
        switch account["type"] as? String {
        case "chatgpt":
            return EngineAccount(email: account["email"] as? String, plan: account["planType"] as? String)
        case "apiKey":
            return EngineAccount(email: nil, plan: "API key")
        default:
            return EngineAccount()
        }
    }

    /// Codex's own ChatGPT sign-in: it gives a URL, the browser does the rest, and the
    /// server says when it is done.
    func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        let (completions, feed) = AsyncStream<Data>.makeStream()
        let listener = subscribe { notification in
            if notification.method == "account/login/completed" { feed.yield(notification.params) }
        }
        defer { unsubscribe(listener) }
        let started = try await request("account/login/start", ["type": "chatgpt"])
        guard let loginID = started["loginId"] as? String,
              let url = (started["authUrl"] as? String).flatMap(URL.init(string:)) else {
            throw ChatError.malformed("Codex gave no sign-in page")
        }
        openURL(url)
        for await params in completions {
            guard let object = HTTPProviderSupport.object(params),
                  object["loginId"] as? String == loginID else { continue }
            if object["success"] as? Bool == true { return }
            throw ChatError.unavailable(object["error"] as? String ?? "Sign-in did not complete.")
        }
    }

    // MARK: The process

    /// A running, initialized server. Starts one if there is none, and initializes it
    /// once however many callers arrive together.
    private func ready() async throws {
        if let process, process.isRunning, let handshake {
            try await handshake.value
            return
        }
        try launch()
        let task = Task { [self] in
            let client: [String: Any] = [
                "clientInfo": ["name": "ultra", "title": "Ultra", "version": "1"],
                "capabilities": ["experimentalApi": false, "requestAttestation": false],
            ]
            _ = try await sendRaw("initialize", params: try HTTPProviderSupport.json(client))
            try notify("initialized", params: Data("{}".utf8))
        }
        handshake = task
        try await task.value
    }

    private func launch() throws {
        guard let executable = ChatEngine.codex.executable else { throw ChatError.notInstalled(.codex) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = Subprocess.environment()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.ended() }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    guard let self else { return }
                    await self.receive(line)
                }
            } catch {}
        }
    }

    private func ended() {
        process = nil
        input = nil
        handshake = nil
        reader?.cancel()
        reader = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: ChatError.unavailable("Codex stopped."))
        }
        pending = [:]
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8), let object = HTTPProviderSupport.object(data) else { return }
        let method = object["method"] as? String
        if let id = object["id"] as? Int, method == nil {
            // A reply to something asked.
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: ChatError.http(
                    status: 0, message: error["message"] as? String ?? "Codex returned an error."))
            } else {
                let result = object["result"]
                let data = (result as? NSNull == nil ? result : nil).flatMap { try? HTTPProviderSupport.json($0) }
                continuation.resume(returning: data ?? Data("{}".utf8))
            }
        } else if let method, let id = object["id"] {
            // Something the server wants of this client — an approval, a question. With
            // approvals off, none should come; one that does is declined rather than left
            // to hang the turn.
            let reply = "{\"id\":\(id),\"error\":{\"code\":-32601,\"message\":\"not supported by Ultra\"}}\n"
            try? input?.write(contentsOf: Data(reply.utf8))
        } else if let method {
            let params = (try? HTTPProviderSupport.json(object["params"] ?? [:])) ?? Data("{}".utf8)
            let notification = Notification(method: method, params: params)
            for listener in listeners.values { listener(notification) }
        }
    }
}
