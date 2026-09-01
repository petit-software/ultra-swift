import Foundation

/// Runs a short-lived command and returns its stdout.
///
/// Off the main thread, with a hard timeout: `lsof` in particular can block indefinitely on
/// a wedged mount, and a tile that polls must never be able to freeze the window.
public enum CommandProbe {

    /// `directory` is the process's working directory. Most callers do not need it — `git`
    /// is told where to look with `-C` — but a command that has no such flag of its own
    /// would otherwise run wherever the APP was launched from, which for a bundled app is
    /// `/`.
    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           directory: URL? = nil,
                           timeout: TimeInterval = 4) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSync(launchPath, arguments,
                                                       directory: directory, timeout: timeout))
            }
        }
    }

    static func runSync(_ launchPath: String,
                        _ arguments: [String],
                        directory: URL? = nil,
                        timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded on purpose: `lsof` reports unreadable sockets on stderr constantly and
        // none of it is actionable from a tile.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return "" }

        // The deadline has to be enforced from OUTSIDE the read loop. `availableData` blocks
        // until the process writes something or exits, so a command that hangs having
        // printed NOTHING — the shape a network call takes when the network is gone — never
        // reaches the check below and pins this thread for as long as it likes.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)
        defer { watchdog.cancel() }

        // Read on this thread while the process runs — waiting first can deadlock on a
        // pipe buffer that fills before the process exits.
        let handle = pipe.fileHandleForReading
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if Date() > deadline {
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A fixed-length ring of samples, for a sparkline.
public struct Samples: Equatable, Sendable {
    public private(set) var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int = 40) { self.capacity = capacity }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var latest: Double { values.last ?? 0 }
    public var peak: Double { values.max() ?? 0 }
}
