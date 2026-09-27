import Foundation

/// `xcrun simctl`, for the verbs that do not need a live connection to the device: listing,
/// booting, shutting down, opening a URL, switching appearance.
///
/// A subprocess rather than CoreSimulator's own calls on purpose. `simctl` is Apple's
/// supported surface and it does not change shape between Xcodes; the private framework is
/// reserved for the two things `simctl` cannot do at all — show the screen live and deliver
/// a touch. If the framework ever fails to load, everything here keeps working.
public enum SimulatorControl {

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Xcode's developer directory, or nil when there is no Xcode at all. Asked once: the
    /// answer costs a fork, and the pane asks on every poll.
    public static let developerDirectory: String? = {
        let output = runSync("/usr/bin/xcode-select", ["-p"], timeout: 5).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, FileManager.default.fileExists(atPath: output) else { return nil }
        return output
    }()

    public static var hasXcode: Bool { developerDirectory != nil }

    public static func listDevices() async throws -> [SimulatorDevice] {
        let result = await run(["simctl", "list", "devices", "--json"], timeout: 15)
        guard result.status == 0, let data = result.output.data(using: .utf8) else {
            throw Failure(result.error.isEmpty ? "simctl list failed" : result.error)
        }
        return try SimulatorDeviceList.parse(data)
    }

    /// Boot returns once the device is up, which can take a while on a cold runtime.
    public static func boot(_ udid: String) async throws {
        try await check(["simctl", "boot", udid], timeout: 120,
                        // Already booted is not a failure to boot.
                        ignoring: "Unable to boot device in current state: Booted")
    }

    public static func shutdown(_ udid: String) async throws {
        try await check(["simctl", "shutdown", udid], timeout: 60,
                        ignoring: "Unable to shutdown device in current state: Shutdown")
    }

    public static func openURL(_ url: URL, on udid: String) async throws {
        try await check(["simctl", "openurl", udid, url.absoluteString], timeout: 20)
    }

    public static func launch(_ bundleID: String, on udid: String) async throws {
        try await check(["simctl", "launch", udid, bundleID], timeout: 60)
    }

    public enum Appearance: String, Sendable { case light, dark }

    public static func appearance(of udid: String) async -> Appearance? {
        let result = await run(["simctl", "ui", udid, "appearance"], timeout: 10)
        return Appearance(rawValue: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func setAppearance(_ appearance: Appearance, on udid: String) async throws {
        try await check(["simctl", "ui", udid, "appearance", appearance.rawValue], timeout: 10)
    }

    /// A PNG of the screen, written where asked. The fallback screenshot path — the live
    /// pane reads the framebuffer directly, but a device with no display connection still
    /// answers this.
    public static func screenshot(_ udid: String, to file: URL) async throws {
        try await check(["simctl", "io", udid, "screenshot", "--type=png", file.path], timeout: 20)
    }

    // MARK: - Running xcrun

    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String
    }

    private static func check(_ arguments: [String], timeout: TimeInterval,
                              ignoring tolerated: String? = nil) async throws {
        let result = await run(arguments, timeout: timeout)
        guard result.status != 0 else { return }
        if let tolerated, result.error.contains(tolerated) { return }
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure(message.isEmpty ? "\(arguments.joined(separator: " ")) failed" : message)
    }

    static func run(_ arguments: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync("/usr/bin/xcrun", arguments, timeout: timeout))
            }
        }
    }

    /// Off the main thread, with a hard deadline: a wedged CoreSimulator service must not
    /// be able to freeze the window.
    public static func runSync(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return Result(status: -1, output: "", error: "\(error)")
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        // stderr is drained on another thread so neither pipe can fill and stall the other.
        let errorBox = DrainedData()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorRead.wait()
        return Result(status: process.terminationStatus,
                      output: String(decoding: outputData, as: UTF8.self),
                      error: String(decoding: errorBox.data, as: UTF8.self))
    }
}

/// One pipe's output, written by the thread that drained it and read after the group has
/// waited on that thread — the group is the synchronisation, so the box needs none.
private final class DrainedData: @unchecked Sendable {
    var data = Data()
}
