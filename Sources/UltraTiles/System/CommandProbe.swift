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
        execute(launchPath, arguments, directory: directory, timeout: timeout,
                mergingErrors: false).output
    }

    /// What a command that CHANGES something came to: whether it worked, and what it said.
    public struct Outcome: Equatable, Sendable {
        public let succeeded: Bool
        /// stdout and stderr together, trimmed. On a failure this is the command's own
        /// reason, which is the only useful thing to show for it.
        public let message: String
    }

    /// Run a command whose failure has to be reported, not swallowed.
    ///
    /// `run` throws stderr away, which is right for a poll — nothing `lsof` complains about
    /// is actionable — and wrong for a verb the user clicked: "it did nothing" is not an
    /// answer to "why can't I remove this worktree".
    public static func attempt(_ launchPath: String,
                               _ arguments: [String],
                               directory: URL? = nil,
                               timeout: TimeInterval = 4) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = execute(launchPath, arguments, directory: directory,
                                     timeout: timeout, mergingErrors: true)
                continuation.resume(returning: Outcome(
                    succeeded: result.status == 0,
                    message: result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    private static func execute(_ launchPath: String,
                                _ arguments: [String],
                                directory: URL?,
                                timeout: TimeInterval,
                                mergingErrors: Bool) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded on purpose for a poll: `lsof` reports unreadable sockets on stderr
        // constantly and none of it is actionable from a tile. Into the SAME pipe when it is
        // wanted, so there is one pipe to drain and no second buffer to fill and deadlock on.
        process.standardError = mergingErrors ? pipe : FileHandle.nullDevice

        do { try process.run() } catch { return (-1, "") }

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
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
