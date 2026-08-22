import Foundation

/// CPU and memory for the processes this workspace started.
///
/// Attribution is by ancestry: every process whose parent chain reaches one of our shells
/// counts as ours. A `npm run dev` that forks four workers should read as one project, not
/// five unrelated rows.
@MainActor
@Observable
public final class ResourcesModel {

    public struct Process: Identifiable, Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let command: String
        public var cpu: Double
        /// Resident size in megabytes.
        public var memory: Double
        public var id: Int32 { pid }
        public var history: Samples = Samples()
    }

    public private(set) var processes: [Process] = []
    public private(set) var totalCPU: Samples = Samples()
    public private(set) var totalMemory: Double = 0
    public private(set) var isRefreshing = false

    /// The shells this workspace owns. Everything descended from them is attributed here.
    public var rootPIDs: Set<Int32> = []
    /// Paused while the window is occluded — a tile polling `ps` behind another window is
    /// pure waste, and it is the exact thing that made the Electron app burn battery.
    public var isPaused = false

    public init() {}

    public func refresh() async {
        guard !isPaused, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let output = await CommandProbe.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,comm="])
        apply(Self.parse(output))
    }

    func apply(_ all: [Process]) {
        let mine = Self.descendants(of: rootPIDs, in: all)
        var previous: [Int32: Samples] = [:]
        for process in processes { previous[process.pid] = process.history }

        processes = mine
            .map { process in
                var updated = process
                var history = previous[process.pid] ?? Samples()
                history.append(process.cpu)
                updated.history = history
                return updated
            }
            .sorted { $0.cpu > $1.cpu }

        totalCPU.append(processes.reduce(0) { $0 + $1.cpu })
        totalMemory = processes.reduce(0) { $0 + $1.memory }
    }

    /// Every process whose parent chain reaches a root. Walks children rather than parents
    /// so a deep tree costs one pass, not one pass per process.
    static func descendants(of roots: Set<Int32>, in all: [Process]) -> [Process] {
        guard !roots.isEmpty else { return [] }
        var childrenByParent: [Int32: [Process]] = [:]
        for process in all { childrenByParent[process.ppid, default: []].append(process) }

        var found: [Process] = []
        var seen: Set<Int32> = []
        var queue = all.filter { roots.contains($0.pid) }
        // A root that ps did not report still needs its children collected.
        queue += roots.filter { root in !all.contains { $0.pid == root } }
            .flatMap { childrenByParent[$0] ?? [] }

        while let process = queue.popLast() {
            guard seen.insert(process.pid).inserted else { continue }
            found.append(process)
            queue += childrenByParent[process.pid] ?? []
        }
        return found
    }

    /// `ps -axo pid=,ppid=,pcpu=,rss=,comm=` — five columns, the last of which may contain
    /// spaces, so it is taken as "the rest of the line".
    static func parse(_ output: String) -> [Process] {
        output.split(separator: "\n").compactMap { line in
            var fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5,
                  let pid = Int32(fields.removeFirst()),
                  let ppid = Int32(fields.removeFirst()),
                  let cpu = Double(fields.removeFirst()),
                  let rss = Double(fields.removeFirst()) else { return nil }
            let command = fields.joined(separator: " ")
            return Process(pid: pid, ppid: ppid,
                           command: (command as NSString).lastPathComponent,
                           cpu: cpu, memory: rss / 1024)
        }
    }
}
