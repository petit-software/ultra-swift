import Foundation

/// One simulator device as CoreSimulator knows it.
///
/// The UDID is the identity — names are not unique, and a user with three "iPhone 17"
/// devices for three test scenarios is exactly the user this pane is for.
public struct SimulatorDevice: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable {
        case shutdown = "Shutdown"
        case booting = "Booting"
        case booted = "Booted"
        case shuttingDown = "Shutting Down"
        case unknown

        public var isBooted: Bool { self == .booted }
    }

    public var udid: String
    public var name: String
    /// The runtime identifier, `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    public var runtime: String
    public var state: State
    public var isAvailable: Bool
    /// The device type, `com.apple.CoreSimulator.SimDeviceType.iPhone-17`: what the
    /// hardware looks like, and so which enclosure to draw. Empty when not known.
    public var deviceType: String

    public var id: String { udid }

    public init(udid: String, name: String, runtime: String, state: State, isAvailable: Bool = true,
                deviceType: String = "") {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.isAvailable = isAvailable
        self.deviceType = deviceType
    }

    /// "iOS 27.0" from `com.apple.CoreSimulator.SimRuntime.iOS-27-0`: the runtime as a
    /// header would print it.
    public var runtimeName: String { Self.runtimeName(of: runtime) }

    public static func runtimeName(of identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    /// Whether the device looks like a phone or a tablet, for the pane's icon and for the
    /// bezel proportions in a preview. Judged by name, which is what `simctl` gives.
    public var isTablet: Bool { name.localizedCaseInsensitiveContains("iPad") }
}

/// `xcrun simctl list devices --json`, decoded.
///
/// Pure, so the parser is tested against a fixture rather than against whatever devices
/// happen to be installed on the machine running the tests.
public enum SimulatorDeviceList {

    /// Devices in the order a picker wants them: booted first, then available, and within
    /// each group the newest runtime first and names alphabetical.
    public static func parse(_ data: Data) throws -> [SimulatorDevice] {
        let decoded = try JSONDecoder().decode(Listing.self, from: data)
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in decoded.devices {
            for entry in entries {
                devices.append(SimulatorDevice(
                    udid: entry.udid, name: entry.name, runtime: runtime,
                    state: SimulatorDevice.State(rawValue: entry.state) ?? .unknown,
                    isAvailable: entry.isAvailable ?? true,
                    deviceType: entry.deviceTypeIdentifier ?? ""))
            }
        }
        return sorted(devices)
    }

    public static func sorted(_ devices: [SimulatorDevice]) -> [SimulatorDevice] {
        devices.sorted { a, b in
            if a.state.isBooted != b.state.isBooted { return a.state.isBooted }
            if a.isAvailable != b.isAvailable { return a.isAvailable }
            if a.runtime != b.runtime {
                return a.runtime.compare(b.runtime, options: .numeric) == .orderedDescending
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Devices grouped by runtime, in the order of `sorted`, for a menu with one section
    /// per OS version.
    public static func grouped(_ devices: [SimulatorDevice]) -> [(runtime: String, devices: [SimulatorDevice])] {
        var order: [String] = []
        var groups: [String: [SimulatorDevice]] = [:]
        for device in sorted(devices) {
            if groups[device.runtime] == nil { order.append(device.runtime) }
            groups[device.runtime, default: []].append(device)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// The device a name or UDID means. A UDID matches exactly; a name matches case-
    /// insensitively and prefers a booted device, since "iPhone 17" from an agent means
    /// the one it just installed its build on.
    public static func find(_ query: String, in devices: [SimulatorDevice]) -> SimulatorDevice? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = devices.first(where: { $0.udid.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        let named = devices.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        return named.first(where: \.state.isBooted) ?? sorted(named).first
    }

    private struct Listing: Decodable {
        var devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        var udid: String
        var name: String
        var state: String
        var isAvailable: Bool?
        var deviceTypeIdentifier: String?
    }
}
