import Foundation

/// Opening a file in the user's editor, as a tool a chat can call.
///
/// The one thing an agent in a shell could do and a chat could not. A shell's agent is
/// handed `ULTRA_AGENT_SOCK`; a chat's engine had no such variable, and in Codex's sandbox
/// no way to reach a socket even with it. So the APP takes the call — Codex asks the client
/// to run it, Claude Code asks an MCP server the app starts — and passes it to the same
/// socket a shell's agent writes to. One door into the app, with one set of rules about
/// what may be opened: a file inside the project, at a line if one is given.
public enum EditorTool {
    public static let name = "open_in_editor"

    /// What Claude Code calls it: MCP tools are named after the server that offers them.
    public static let claudeName = "mcp__ultra__\(name)"

    /// The flag that makes the app's own executable the MCP server, on stdio, instead of
    /// the app — see `EditorMCPServer`. It is followed by the socket's path.
    public static let serverFlag = "--chat-editor-mcp"

    public static var tool: ChatTool {
        ChatTool(name: name,
                 description: "Open a file of the project in the user's editor, optionally at a line. "
                    + "Use it when the user asks to see or open a file.",
                 parameters: [
                    .init("path", .string, "File, relative to the project root, or absolute.", isRequired: true),
                    .init("line", .integer, "Line to show, from 1. Omit for the top."),
                 ])
    }

    /// Run a call against the socket. Blocks until the app answers, so it is for a thread
    /// that may wait: the MCP server's own, or a detached task.
    public static func run(_ call: ChatToolCall, socket: String) -> (ok: Bool, text: String) {
        guard let path = call.string("path"), !path.isEmpty else {
            return (false, "Error: say which file to open, as path.")
        }
        var request: [String: Any] = ["verb": "open", "path": path]
        if let line = call.integer("line"), line > 0 { request["line"] = line }
        do {
            var line = try HTTPProviderSupport.json(request)
            line.append(UInt8(ascii: "\n"))
            let reply = HTTPProviderSupport.object(try AgentSocket.exchange(line, at: socket)) ?? [:]
            if reply["ok"] as? Bool == true { return (true, "Opened \(path) in the editor.") }
            return (false, "Error: \(reply["error"] as? String ?? "the editor did not open \(path).")")
        } catch {
            return (false, "Error: Ultra is not answering, so \(path) was not opened.")
        }
    }

    public static func run(_ call: ChatToolCall, socket: String) async -> (ok: Bool, text: String) {
        await Task.detached { run(call, socket: socket) }.value
    }

    /// Claude Code's `--mcp-config`: this tool's server, and nothing else.
    public static func mcpConfig(executable: String, socket: String) -> String {
        let config: [String: Any] = ["mcpServers": ["ultra": [
            "type": "stdio", "command": executable, "args": [serverFlag, socket],
        ]]]
        return (try? HTTPProviderSupport.json(config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The app's own executable, which is the MCP server when started with `serverFlag`.
    public static var executable: String? { Bundle.main.executablePath }
}

/// A toolbox with the editor in it, for the chats that run their tools in the app.
public struct EditorToolbox: ChatToolbox {
    public let base: any ChatToolbox
    public let socket: String

    public init(base: any ChatToolbox, socket: String) {
        self.base = base
        self.socket = socket
    }

    public var tools: [ChatTool] { base.tools + [EditorTool.tool] }

    public func run(_ call: ChatToolCall) async -> String {
        guard call.name == EditorTool.name else { return await base.run(call) }
        return await EditorTool.run(call, socket: socket).text
    }
}

/// One line to the app's agent socket and the one line it answers with.
enum AgentSocket {
    struct Failure: Error {}

    /// Longer than the channel gives a handler, so its own "timed out" is what comes back.
    static let timeout = 70

    static func exchange(_ line: Data, at path: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure() }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure() }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure() }
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw Failure() }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(UInt8(ascii: "\n")) {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[..<count])
        }
        guard !reply.isEmpty else { throw Failure() }
        return reply
    }
}

/// The editor tool as an MCP server on stdio, for Claude Code.
///
/// Claude Code runs a chat's tools itself, so the app cannot answer a call the way it does
/// for Codex; what it can do is be the MCP server Claude Code starts. The app's executable,
/// started with `EditorTool.serverFlag`, runs this instead of the app — JSON-RPC, a line
/// each way — and lives as long as the turn does.
public enum EditorMCPServer {
    public static func run(socket: String) -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let message = HTTPProviderSupport.object(Data(line.utf8)),
                  let reply = reply(to: message, socket: socket),
                  var data = try? HTTPProviderSupport.json(reply) else { continue }
            data.append(UInt8(ascii: "\n"))
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    /// The answer to one message; nil for a notification, which has none.
    static func reply(to message: [String: Any], socket: String) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            return result(id, [
                // The client's own version: this server uses nothing a version changed.
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "ultra", "version": "1"],
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            let tool = EditorTool.tool
            return result(id, ["tools": [[
                "name": tool.name, "description": tool.description, "inputSchema": tool.schema(),
            ]]])
        case "tools/call":
            guard params["name"] as? String == EditorTool.name else {
                return error(id, -32602, "Ultra has no tool called \(params["name"] as? String ?? "that").")
            }
            let arguments = (try? HTTPProviderSupport.json(params["arguments"] ?? [:]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let outcome = EditorTool.run(ChatToolCall(id: "", name: EditorTool.name, arguments: arguments),
                                         socket: socket)
            return result(id, ["content": [["type": "text", "text": outcome.text]], "isError": !outcome.ok])
        default:
            return error(id, -32601, "Ultra does not answer \(message["method"] as? String ?? "that").")
        }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
