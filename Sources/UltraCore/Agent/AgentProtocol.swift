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
    /// Show a simulator device in a Simulator pane, booting it if it is shut down, and
    /// optionally launch an app on it. The agent installs and launches through `xcrun
    /// simctl` in its own shell; this verb is only "put it on screen".
    case simulator
    /// Show a web page in a Browser pane: the dev server just started, the docs being
    /// followed. `http` and `https` only — a pane is not a place to open `file:` or a
    /// custom scheme from a process that cannot see the screen.
    case browse
}

/// One request, as it arrives on the wire: a single line of JSON.
public struct AgentRequest: Codable, Equatable, Sendable {
    public var verb: AgentVerb
    /// Relative to the workspace root, or absolute. Either way it must RESOLVE inside the
    /// root — see `AgentRequest.resolve`. Required by `open` and `reveal`.
    public var path: String?
    /// 1-based, to match every editor and compiler the user already reads.
    public var line: Int?
    /// `simulator`: the device, by name ("iPhone 17") or UDID. Required.
    public var device: String?
    /// `simulator`: a bundle identifier to launch once the device is up.
    public var app: String?
    /// `browse`: the page, as typed — `localhost:3000` is enough. Required.
    public var url: String?

    public init(verb: AgentVerb, path: String? = nil, line: Int? = nil,
                device: String? = nil, app: String? = nil, url: String? = nil) {
        self.verb = verb
        self.path = path
        self.line = line
        self.device = device
        self.app = app
        self.url = url
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
    /// The file, for `open` and `reveal`. Nil for `simulator`, which names no path.
    public let url: URL?
    public let line: Int?
    public let device: String?
    public let app: String?
    /// The page, for `browse`, as the agent typed it: the app turns it into a URL with the
    /// same rules the address field uses.
    public let address: String?

    public init(verb: AgentVerb, url: URL?, line: Int? = nil, device: String? = nil,
                app: String? = nil, address: String? = nil) {
        self.verb = verb
        self.url = url
        self.line = line
        self.device = device
        self.app = app
        self.address = address
    }
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
        if verb == .simulator {
            // No path to judge: the device is looked up by the app against the machine's
            // simulators, and a bundle id is handed to `simctl launch`, which refuses what
            // is not installed. Both are checked for shape here so a mistake is named.
            guard let device = device?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !device.isEmpty else {
                throw AgentRequestError.malformed("simulator needs a device name or UDID")
            }
            // An empty app is no app; one with spaces in it is not a bundle identifier.
            let app = app?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let app, app.contains(where: \.isWhitespace) {
                throw AgentRequestError.malformed("app must be a bundle identifier")
            }
            return ResolvedAgentRequest(verb: verb, url: nil, device: device, app: app)
        }
        if verb == .browse {
            guard let address = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw AgentRequestError.malformed("browse needs a url")
            }
            // The scheme is judged here, before anything is opened: only the web. What has
            // no scheme gets one from the address field's rules later, which are also web-only.
            if let scheme = URL(string: address)?.scheme?.lowercased(), address.contains("://"),
               scheme != "http", scheme != "https" {
                throw AgentRequestError.malformed("browse opens http and https pages only")
            }
            return ResolvedAgentRequest(verb: verb, url: nil, address: address)
        }
        guard let path, !path.isEmpty else { throw AgentRequestError.malformed("empty path") }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
