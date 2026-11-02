import Foundation
import Testing
@testable import UltraChat
@testable import UltraCore
@testable import UltraTiles

/// A chat opening a file in the editor: the tool reaches the workspace's agent socket as the
/// same `open` request a shell's agent writes, by each road a chat can take to it.
@Suite("Chat editor tool")
@MainActor
struct ChatEditorToolTests {

    /// A channel that records what it was asked, and answers `ok` or the given error.
    private func channel(failing error: String? = nil) -> (AgentChannel, Mailbox) {
        let received = Mailbox()
        let channel = AgentChannel(socketURL: AgentChannel.defaultSocketURL(for: UUID())) { request in
            received.store(request)
            return error.map(AgentResponse.failure) ?? .success
        }
        return (channel, received)
    }

    private func settle(_ store: ChatStore) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if !store.isStreaming { return }
        }
        Issue.record("the answer never finished")
    }

    private func call(_ arguments: String) -> ChatToolCall {
        ChatToolCall(id: "1", name: EditorTool.name, arguments: arguments)
    }

    @Test("a call is an open request on the socket, with its line")
    func callOpens() async {
        let (channel, received) = channel()
        #expect(channel.start())
        defer { channel.stop() }

        let outcome = await EditorTool.run(call(#"{"path":"Tailor feedback.md","line":"12"}"#),
                                           socket: channel.socketURL.path)
        #expect(outcome.ok)
        #expect(received.value?.verb == .open)
        #expect(received.value?.path == "Tailor feedback.md")
        #expect(received.value?.line == 12)
    }

    @Test("the app's refusal is what the model reads; no app is said plainly")
    func failuresAreText() async {
        let (channel, _) = channel(failing: "refused: /etc/hosts is outside the workspace")
        #expect(channel.start())
        defer { channel.stop() }

        let refused = await EditorTool.run(call(#"{"path":"/etc/hosts"}"#), socket: channel.socketURL.path)
        #expect(!refused.ok)
        #expect(refused.text.contains("outside the workspace"))

        let missing = await EditorTool.run(call(#"{"path":"a.swift"}"#), socket: "/nonexistent/ultra.sock")
        #expect(!missing.ok)
        #expect(missing.text.contains("not answering"))

        let pathless = await EditorTool.run(call("{}"), socket: channel.socketURL.path)
        #expect(!pathless.ok)
    }

    @Test("the MCP server introduces itself, lists the tool, and answers a call through the socket")
    func mcpServer() async {
        let (channel, received) = channel()
        #expect(channel.start())
        defer { channel.stop() }
        let socket = channel.socketURL.path

        let hello = EditorMCPServer.reply(to: ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                               "params": ["protocolVersion": "2025-06-18"]], socket: socket)
        let info = hello?["result"] as? [String: Any]
        #expect(info?["protocolVersion"] as? String == "2025-06-18")
        #expect((info?["capabilities"] as? [String: Any])?["tools"] != nil)

        #expect(EditorMCPServer.reply(to: ["jsonrpc": "2.0", "method": "notifications/initialized"],
                                      socket: socket) == nil)

        let list = EditorMCPServer.reply(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], socket: socket)
        let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.map { $0["name"] as? String } == [EditorTool.name])
        #expect((tools?.first?["inputSchema"] as? [String: Any])?["required"] as? [String] == ["path"])

        // Off the main actor: the channel answers there.
        let isError = await Task.detached {
            let answer = EditorMCPServer.reply(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                    "params": ["name": EditorTool.name,
                                                               "arguments": ["path": "a.swift", "line": 3]]],
                                               socket: socket)?["result"] as? [String: Any]
            return answer?["isError"] as? Bool
        }.value
        #expect(isError == false)
        #expect(received.value?.path == "a.swift")
        #expect(received.value?.line == 3)

        let other = EditorMCPServer.reply(to: ["jsonrpc": "2.0", "id": 3, "method": "resources/list"], socket: socket)
        #expect(other?["error"] != nil)
    }

    @Test("Claude Code gets the app as its one MCP server, with the tool allowed")
    func claudeArguments() {
        let plain = ClaudeCodeProvider.arguments(model: "default", system: nil, session: "s", resume: false)
        #expect(!plain.contains("--mcp-config"))

        let arguments = ClaudeCodeProvider.arguments(model: "default", system: nil, session: "s", resume: false,
                                                     editor: ("/Applications/Ultra.app/Contents/MacOS/Ultra", "/tmp/u.sock"))
        let allowed = arguments.firstIndex(of: "--allowedTools")!
        #expect(arguments[allowed + 1] == "WebSearch,WebFetch,\(EditorTool.claudeName)")
        #expect(arguments.contains("--strict-mcp-config"))
        let config = arguments.firstIndex(of: "--mcp-config")!
        let servers = (HTTPProviderSupport.object(Data(arguments[config + 1].utf8))?["mcpServers"] as? [String: Any])
        let server = servers?["ultra"] as? [String: Any]
        #expect(servers?.count == 1)
        #expect(server?["command"] as? String == "/Applications/Ultra.app/Contents/MacOS/Ultra")
        #expect(server?["args"] as? [String] == [EditorTool.serverFlag, "/tmp/u.sock"])
        // Whatever follows the config is a flag, so the list cannot swallow it.
        #expect(arguments[config + 2].hasPrefix("--"))
    }

    @Test("Codex is told of the tool in the shape thread/start takes")
    func codexTool() {
        let tool = CodexProvider.dynamicTool(EditorTool.tool)
        #expect(tool["type"] as? String == "function")
        #expect(tool["name"] as? String == EditorTool.name)
        #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test("a send hands over the socket, the tool and the prompt that names it; none without one")
    func storeHandsOver() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-chat-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ChatStoreTests.ScriptedProvider(events: [.finished(ChatFinish(reason: .complete))])
        let store = ChatStore(root: root, makeProvider: { _ in provider })
        store.setProvider(.anthropic)

        store.send("hello")
        try await settle(store)
        store.agentSocket = { "/tmp/u.sock" }
        store.send("open the readme")
        try await settle(store)

        try #require(provider.requests.count == 2)
        let (without, with) = (provider.requests[0], provider.requests[1])
        #expect(without.agentSocket == nil)
        #expect(!without.tools.map(\.name).contains(EditorTool.name))
        #expect(without.system?.contains(EditorTool.name) == false)
        #expect(with.agentSocket == "/tmp/u.sock")
        #expect(with.tools.map(\.name).contains(EditorTool.name))
        #expect(with.system?.contains(EditorTool.name) == true)
    }

    @Test("the row under an answer says what was opened")
    func summary() {
        #expect(ProjectFiles.summary(of: call(#"{"path":"README.md"}"#)) == "Open README.md in the editor")
        let claude = ChatToolCall(id: "1", name: EditorTool.claudeName, arguments: #"{"path":"a.swift"}"#)
        #expect(ProjectFiles.summary(of: claude) == "Open a.swift in the editor")
    }
}

private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentRequest?
    func store(_ request: AgentRequest) { lock.lock(); stored = request; lock.unlock() }
    var value: AgentRequest? { lock.lock(); defer { lock.unlock() }; return stored }
}
