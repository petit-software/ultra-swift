import Foundation

/// What an agent running in a pane may ask the app to do.
///
/// A SMALL, CLOSED set. There is deliberately no `eval`, no "run this command", and no way
/// to add a verb at runtime: the agent already has a shell for running things, and a verb
/// list that can grow without review is an injection surface rather than a feature.
public enum AgentVerb: String, Codable, Sendable, CaseIterable {
    /// Open a file in an Editor pane, optionally at a line.
    case open
    /// Show a path in a File Tree pane without opening it.
    case reveal
}

/// One request, as it arrives on the wire: a single line of JSON.
public struct AgentRequest: Codable, Equatable, Sendable {
    public var verb: AgentVerb
    /// Relative to the workspace root, or absolute. Either way it must RESOLVE inside the
    /// root — see `AgentRequest.resolve`.
    public var path: String
    /// 1-based, to match every editor and compiler the user already reads.
    public var line: Int?

    public init(verb: AgentVerb, path: String, line: Int? = nil) {
        self.verb = verb
        self.path = path
        self.line = line
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?

    public static let success = AgentResponse(ok: true, error: nil)
    public static func failure(_ message: String) -> AgentResponse {
        AgentResponse(ok: false, error: message)
    }
}

public enum AgentRequestError: Error, Equatable, Sendable {
    case malformed(String)
    case outsideWorkspace(String)
    case notFound(String)

    public var message: String {
        switch self {
        case .malformed(let detail): "malformed request: \(detail)"
        case .outsideWorkspace(let path): "refused: \(path) is outside the workspace"
        case .notFound(let path): "no such file: \(path)"
        }
    }
}

/// A request that has been checked and is safe to act on.
public struct ResolvedAgentRequest: Equatable, Sendable {
    public let verb: AgentVerb
    public let url: URL
    public let line: Int?
}

public extension AgentRequest {

    /// Decode one line of JSON.
    static func decode(line: String) throws -> AgentRequest {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentRequestError.malformed("empty line") }
        guard let data = trimmed.data(using: .utf8) else {
            throw AgentRequestError.malformed("not UTF-8")
        }
        do {
            return try JSONDecoder().decode(AgentRequest.self, from: data)
        } catch {
            throw AgentRequestError.malformed(String(describing: error))
        }
    }

    /// Resolve the path against the workspace and refuse anything that escapes it.
    ///
    /// REFUSED, not clamped. Silently rewriting `../../etc/passwd` into something inside the
    /// root would hide the attempt; an error puts it in front of a human. Symlinks are
    /// resolved before the check, because a link inside the workspace pointing out of it is
    /// the interesting case and a textual prefix test misses it entirely.
    func resolve(in root: URL, fileManager: FileManager = .default) throws -> ResolvedAgentRequest {
        guard !path.isEmpty else { throw AgentRequestError.malformed("empty path") }
        if let line, line < 1 { throw AgentRequestError.malformed("line must be 1-based") }

        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        // A path that does not exist yet still has to be judged, so the check walks up to
        // the nearest existing ancestor rather than giving up.
        var probe = candidate.standardizedFileURL
        while !fileManager.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let resolvedProbe = probe.resolvingSymlinksInPath().standardizedFileURL

        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedProbe.path == resolvedRoot.path || resolvedProbe.path.hasPrefix(rootPath) else {
            throw AgentRequestError.outsideWorkspace(path)
        }

        let target = candidate.standardizedFileURL
        guard fileManager.fileExists(atPath: target.path) else {
            throw AgentRequestError.notFound(path)
        }
        return ResolvedAgentRequest(verb: verb, url: target, line: line)
    }
}
