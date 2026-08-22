import Testing
import Foundation
@testable import UltraCore

/// The agent channel is a control surface, so its refusals matter more than its successes.
@Suite("Agent protocol")
struct AgentProtocolTests {

    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"),
                                                withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("Sources/Main.swift"),
                      atomically: true, encoding: .utf8)
        return root
    }

    @Test("a well-formed line decodes")
    func decoding() throws {
        let request = try AgentRequest.decode(line: #"{"verb":"open","path":"a.swift","line":12}"#)
        #expect(request.verb == .open)
        #expect(request.path == "a.swift")
        #expect(request.line == 12)
    }

    @Test("garbage is refused, not guessed at", arguments: [
        "", "   ", "not json", "{}", #"{"verb":"eval","path":"x"}"#,
        #"{"verb":"open"}"#, "[1,2,3]",
    ])
    func malformedInput(line: String) {
        #expect(throws: (any Error).self) { try AgentRequest.decode(line: line) }
    }

    @Test("a relative path inside the workspace resolves")
    func resolvesInside() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try AgentRequest(verb: .open, path: "Sources/Main.swift").resolve(in: root)
        #expect(resolved.url.lastPathComponent == "Main.swift")
    }

    /// The whole point of the trust model: an escape is REFUSED, not quietly rewritten into
    /// something inside the root, because a silent correction hides the attempt.
    @Test("paths that escape the workspace are refused", arguments: [
        "../outside.txt", "../../etc/passwd", "/etc/passwd", "Sources/../../escape",
    ])
    func refusesEscapes(path: String) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AgentRequestError.outsideWorkspace(path)) {
            try AgentRequest(verb: .open, path: path).resolve(in: root)
        }
    }

    /// A textual prefix check passes this and should not: the link lives inside the
    /// workspace but points out of it.
    @Test("a symlink pointing out of the workspace is refused")
    func refusesSymlinkEscape() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-outside-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: AgentRequestError.outsideWorkspace("link.txt")) {
            try AgentRequest(verb: .open, path: "link.txt").resolve(in: root)
        }
    }

    @Test("a missing file inside the workspace is 'not found', not 'refused'")
    func missingFile() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AgentRequestError.notFound("Sources/Nope.swift")) {
            try AgentRequest(verb: .open, path: "Sources/Nope.swift").resolve(in: root)
        }
    }

    @Test("a zero or negative line is refused")
    func badLine() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try AgentRequest(verb: .open, path: "Sources/Main.swift", line: 0).resolve(in: root)
        }
    }

    @Test("the verb list is closed")
    func verbsAreClosed() {
        #expect(Set(AgentVerb.allCases.map(\.rawValue)) == ["open", "reveal"],
                "adding a verb is a deliberate act, not a side effect")
    }
}

@Suite("Agent channel", .serialized)
struct AgentChannelTests {

    @Test("a request written to the socket is served and answered")
    func roundTrip() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let received = Mailbox()
        let channel = AgentChannel(socketURL: AgentChannel.defaultSocketURL(for: UUID())) { request in
            received.store(request)
            return .success
        }
        #expect(channel.start(), "the socket should bind")
        defer { channel.stop() }

        let reply = try await send(#"{"verb":"open","path":"f.txt","line":3}"#,
                                   to: channel.socketURL)
        #expect(reply.contains("\"ok\":true"))
        #expect(received.value?.path == "f.txt")
        #expect(received.value?.line == 3)
    }

    @Test("a malformed line is answered with an error rather than dropped")
    func malformedIsAnswered() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let channel = AgentChannel(socketURL: AgentChannel.defaultSocketURL(for: UUID())) { _ in
            .success
        }
        #expect(channel.start())
        defer { channel.stop() }

        let reply = try await send("this is not json", to: channel.socketURL)
        #expect(reply.contains("\"ok\":false"))
        #expect(reply.contains("malformed"))
    }

    /// The regression test for a crash: the handler used to run on the serving queue, so
    /// anything reaching for the main actor trapped and one well-formed request took the app
    /// down. The hop belongs to the channel, and this is what says so.
    @Test("handlers run on the main thread")
    func handlerRunsOnMain() async throws {
        let onMain = Flag()
        let channel = AgentChannel(socketURL: AgentChannel.defaultSocketURL(for: UUID())) { _ in
            onMain.set(Thread.isMainThread)
            return .success
        }
        #expect(channel.start())
        defer { channel.stop() }

        _ = try await send(#"{"verb":"reveal","path":"anything"}"#, to: channel.socketURL)
        #expect(onMain.value == true)
    }

    @Test("the socket is private to this user")
    func permissions() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let channel = AgentChannel(socketURL: AgentChannel.defaultSocketURL(for: UUID())) { _ in
            .success
        }
        #expect(channel.start())
        defer { channel.stop() }

        let mode = try FileManager.default
            .attributesOfItem(atPath: channel.socketURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600, "another user on the machine must not be able to connect")
    }

    /// Minimal client: connect, write one line, read the reply.
    private func send(_ line: String, to socketURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let client = socket(AF_UNIX, SOCK_STREAM, 0)
                defer { close(client) }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                    socketURL.path.withCString { source in
                        strncpy(UnsafeMutableRawPointer(pointer)
                            .assumingMemoryBound(to: CChar.self), source, 103)
                    }
                }
                let size = socklen_t(MemoryLayout<sockaddr_un>.size)
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(client, $0, size)
                    }
                }
                guard connected == 0 else {
                    continuation.resume(returning: "<could not connect>"); return
                }
                let payload = Array((line + "\n").utf8)
                _ = payload.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(client, &buffer, buffer.count)
                continuation.resume(returning: count > 0
                    ? String(decoding: buffer[0..<count], as: UTF8.self) : "")
            }
        }
    }
}

/// Carries a value back from the handler safely.
private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentRequest?
    func store(_ request: AgentRequest) { lock.lock(); stored = request; lock.unlock() }
    var value: AgentRequest? { lock.lock(); defer { lock.unlock() }; return stored }
}


private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}
