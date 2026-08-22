import Foundation

/// Runs a short-lived command and returns its stdout.
///
/// Off the main thread, with a hard timeout: `lsof` in particular can block indefinitely on
/// a wedged mount, and a tile that polls must never be able to freeze the window.
public enum CommandProbe {

    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           timeout: TimeInterval = 4) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSync(launchPath, arguments, timeout: timeout))
            }
        }
    }

    static func runSync(_ launchPath: String,
                        _ arguments: [String],
                        timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded on purpose: `lsof` reports unreadable sockets on stderr constantly and
        // none of it is actionable from a tile.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return "" }

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
