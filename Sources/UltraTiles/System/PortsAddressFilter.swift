import Foundation

/// Which listeners a Ports pane shows, by the address they are bound to.
///
/// Three groups and an exact address. The groups are the question usually being asked —
/// "what is reachable only from this Mac" against "what is open to the network" — and an
/// exact address is for the machine with a second interface, a VPN or a container bridge.
/// `lsof` writes the wildcard as `*`, but a server can name `0.0.0.0` or `::` itself, so
/// each group recognises every spelling of itself.
public enum PortsAddressFilter: Codable, Hashable, Sendable {
    case all
    /// 127.0.0.0/8, `::1` and `localhost`: reachable only from this Mac.
    case loopback
    /// `*`, `0.0.0.0` and `::`: every interface, so the network can reach it.
    case anyInterface
    case exact(String)

    public func matches(_ address: String) -> Bool {
        switch self {
        case .all: true
        case .loopback: Self.isLoopback(address)
        case .anyInterface: Self.isAnyInterface(address)
        case .exact(let wanted): address == wanted
        }
    }

    public var title: String {
        switch self {
        case .all: "All Addresses"
        case .loopback: "Loopback Only"
        case .anyInterface: "All Interfaces Only"
        case .exact(let address): address
        }
    }

    /// For a sentence: "Nothing listening on loopback".
    public var phrase: String {
        switch self {
        case .all: "any address"
        case .loopback: "loopback"
        case .anyInterface: "all interfaces"
        case .exact(let address): address
        }
    }

    public static func isLoopback(_ address: String) -> Bool {
        let lowered = address.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
    }

    public static func isAnyInterface(_ address: String) -> Bool {
        address == "*" || address == "0.0.0.0" || address == "::"
    }

    /// The pane's record carries the filter only when it is not `.all`, so a pane that was
    /// never filtered writes nothing new.
    public var encoded: Data? {
        self == .all ? nil : try? JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data?) -> PortsAddressFilter {
        data.flatMap { try? JSONDecoder().decode(PortsAddressFilter.self, from: $0) } ?? .all
    }
}
