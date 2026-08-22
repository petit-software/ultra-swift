import Foundation

/// Listening TCP ports, and which process owns each one.
///
/// `lsof` is the only thing on macOS that maps a listening socket to a pid without
/// entitlements. Parsing is deliberately defensive: its output format varies by version and
/// a tile must degrade to "no ports" rather than showing nonsense.
@MainActor
@Observable
public final class PortsModel {

    public struct Port: Identifiable, Equatable, Sendable {
        public let pid: Int32
        public let command: String
        public let port: Int
        public let address: String
        public var id: String { "\(pid)-\(port)-\(address)" }
        /// True when this port belongs to a process started by one of our shells.
        public var isOurs: Bool = false
        public var url: URL? { URL(string: "http://localhost:\(port)") }
    }

    public private(set) var ports: [Port] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?

    /// pids descended from our shells, so a project's own dev server can be told apart from
    /// every other listener on the machine.
    public var ownedPIDs: Set<Int32> = [] {
        didSet { attribute() }
    }

    public init() {}

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let output = await CommandProbe.run("/usr/sbin/lsof",
                                            ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnT"])
        ports = Self.parse(output)
        attribute()
        lastError = output.isEmpty ? "lsof returned nothing" : nil
    }

    private func attribute() {
        for index in ports.indices {
            ports[index].isOurs = ownedPIDs.contains(ports[index].pid)
        }
    }

    /// Parse `lsof -F` field output: one field per line, tagged by its first character.
    /// `p` starts a process block, `n` is the socket name within it.
    static func parse(_ output: String) -> [Port] {
        var result: [Port] = []
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let (address, port) = splitAddress(value) else { continue }
                let entry = Port(pid: pid, command: command, port: port, address: address)
                // lsof lists IPv4 and IPv6 rows for the same listener; one row per port.
                if !result.contains(where: { $0.pid == entry.pid && $0.port == entry.port }) {
                    result.append(entry)
                }
            default: continue
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// `*:3000`, `127.0.0.1:8080`, `[::1]:5432` — the address is whatever precedes the last
    /// colon, which is the only rule that survives IPv6.
    static func splitAddress(_ name: String) -> (String, Int)? {
        guard let separator = name.lastIndex(of: ":") else { return nil }
        let portText = name[name.index(after: separator)...]
        guard let port = Int(portText), port > 0 else { return nil }
        var address = String(name[..<separator])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        return (address.isEmpty ? "*" : address, port)
    }

    /// SIGTERM, never SIGKILL: a dev server asked to stop should get to clean up. The tile
    /// offers no force-kill, because "it did not die" is information the user wants.
    public func terminate(_ port: Port) {
        kill(port.pid, SIGTERM)
    }
}
