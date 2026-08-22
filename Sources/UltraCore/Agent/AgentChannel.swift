import Foundation

/// A Unix-domain socket an agent in a pane can talk to.
///
/// A SOCKET, not terminal escape sequences. An escape sequence lives in scrollback and
/// replays every time the buffer is redrawn, and anything that can write to the tty — a
/// `cat` of a hostile file, a compiler printing attacker-controlled bytes — could drive the
/// app. A socket is addressed by the process that was handed its path, and the path only
/// reaches processes this app spawned.
///
/// Mode 0600 and inside the workspace, so another user on the machine cannot connect.
public final class AgentChannel: @unchecked Sendable {

    public typealias Handler = @Sendable (AgentRequest) -> AgentResponse

    public private(set) var socketURL: URL
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.ultra.agent-channel")
    private let handler: Handler

    /// Where a workspace's socket goes.
    ///
    /// NOT inside the project, however much nicer `.ultra/agent.sock` would read. A
    /// `sockaddr_un` path is 104 BYTES, and a checkout a few directories deep blows straight
    /// through that — `bind` then fails and the channel is silently dead for exactly the
    /// users with the most organised source trees. The temp directory plus a short name
    /// always fits, and the agent is handed the path in its environment anyway, so nothing
    /// depends on the location being guessable.
    public static func defaultSocketURL(for workspaceID: UUID) -> URL {
        let short = workspaceID.uuidString.prefix(8).lowercased()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-\(short).sock")
    }

    /// - Parameter handler: called ON THE MAIN THREAD for every well-formed request.
    ///
    ///   Delivering on the serving queue instead would be faster and is what this did first,
    ///   and it was wrong: acting on a request means touching panes, so every handler has to
    ///   reach the main actor, and `MainActor.assumeIsolated` from the serving queue TRAPS.
    ///   One well-formed request crashed the app. A contract that every caller must remember
    ///   in order not to crash is a defect in the contract, so the hop lives here.
    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit { stop() }

    // MARK: Lifecycle

    @discardableResult
    public func start() -> Bool {
        stop()
        let path = socketURL.path
        guard path.utf8.count < 104 else { return false }   // sun_path is 104 bytes

        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A socket file left by a crash would make bind fail with EADDRINUSE.
        try? FileManager.default.removeItem(at: socketURL)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                        source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener); listener = -1
            return false
        }
        // Only this user. The socket is the app's control surface, so it is not shared.
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { [listener] in if listener >= 0 { close(listener) } }
        source.resume()
        self.source = source
        return true
    }

    public func stop() {
        source?.cancel()
        source = nil
        listener = -1
        try? FileManager.default.removeItem(at: socketURL)
    }

    // MARK: Serving

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // One request per connection, and a hard ceiling on how much will be read. An
        // unbounded read here is a memory bug waiting for a client that never sends a
        // newline.
        var buffer = [UInt8](repeating: 0, count: 8192)
        var accumulated = Data()
        while accumulated.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            accumulated.append(contentsOf: buffer[0..<count])
            if accumulated.contains(UInt8(ascii: "\n")) { break }
        }
        guard let line = String(data: accumulated, encoding: .utf8) else {
            respond(.failure("not UTF-8"), to: client)
            return
        }
        do {
            let request = try AgentRequest.decode(line: line)
            // Synchronous: the reply has to say what actually happened, and this queue has
            // nothing else to do meanwhile. Safe from deadlock because `acceptOne` only ever
            // runs on the serving queue, never on main.
            let response = DispatchQueue.main.sync { handler(request) }
            respond(response, to: client)
        } catch let error as AgentRequestError {
            respond(.failure(error.message), to: client)
        } catch {
            respond(.failure("\(error)"), to: client)
        }
    }

    private func respond(_ response: AgentResponse, to client: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
    }
}
