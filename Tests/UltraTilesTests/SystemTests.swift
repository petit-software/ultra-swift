import Testing
import Foundation
@testable import UltraTiles

@Suite("Ports")
@MainActor
struct PortsTests {
    /// Real `lsof -F` output shape, including the IPv4/IPv6 duplicate a listener produces.
    private let sample = """
    p4321
    cnode
    n*:3000
    n[::1]:3000
    p777
    cpostgres
    n127.0.0.1:5432
    p90
    cControlCe
    n*:7000
    """

    @Test("field output parses to one row per listener")
    func parsing() {
        let ports = PortsModel.parse(sample)
        #expect(ports.map(\.port) == [3000, 5432, 7000])
        #expect(ports.first?.command == "node")
        #expect(ports.first?.pid == 4321)
    }

    @Test("IPv6 and IPv4 rows for one listener collapse to a single entry")
    func deduplicates() {
        #expect(PortsModel.parse(sample).filter { $0.port == 3000 }.count == 1)
    }

    @Test("addresses split on the LAST colon, so IPv6 survives")
    func addressSplitting() {
        #expect(PortsModel.splitAddress("*:3000")?.0 == "*")
        #expect(PortsModel.splitAddress("*:3000")?.1 == 3000)
        #expect(PortsModel.splitAddress("127.0.0.1:8080")?.0 == "127.0.0.1")
        #expect(PortsModel.splitAddress("127.0.0.1:8080")?.1 == 8080)
        #expect(PortsModel.splitAddress("[::1]:5432")?.0 == "::1", "brackets are stripped")
        #expect(PortsModel.splitAddress("[::1]:5432")?.1 == 5432)
        #expect(PortsModel.splitAddress("garbage") == nil)
        #expect(PortsModel.splitAddress("host:notaport") == nil)
    }

    @Test("garbage in does not produce rows")
    func robustness() {
        #expect(PortsModel.parse("").isEmpty)
        #expect(PortsModel.parse("total garbage\nnot lsof output").isEmpty)
    }
}

@Suite("Resources")
@MainActor
struct ResourcesTests {
    private let sample = """
      501   1  0.5  12000 launchd
      900 501  1.5  40000 /bin/zsh
      901 900 12.0 250000 /usr/local/bin/node
      902 901  3.0  80000 esbuild
      999   1 90.0 999000 unrelated
    """

    @Test("ps columns parse, with the command taken as the rest of the line")
    func parsing() {
        let all = ResourcesModel.parse(sample)
        #expect(all.count == 5)
        let node = try! #require(all.first { $0.pid == 901 })
        #expect(node.ppid == 900)
        #expect(node.cpu == 12.0)
        #expect(node.command == "node", "the path is trimmed to its last component")
        #expect(abs(node.memory - 244.14) < 0.1, "rss is reported in KB, shown in MB")
    }

    @Test("attribution follows the whole parent chain, not just direct children")
    func descendants() {
        let all = ResourcesModel.parse(sample)
        let mine = ResourcesModel.descendants(of: [900], in: all)
        #expect(Set(mine.map(\.pid)) == [900, 901, 902],
                "esbuild is a grandchild of the shell and is still ours")
        #expect(!mine.contains { $0.pid == 999 })
    }

    @Test("no roots means nothing is attributed")
    func noRoots() {
        #expect(ResourcesModel.descendants(of: [], in: ResourcesModel.parse(sample)).isEmpty)
    }

    @Test("a sample ring keeps only its capacity, newest last")
    func samplesRing() {
        var samples = Samples(capacity: 3)
        for value in [1.0, 2, 3, 4, 5] { samples.append(value) }
        #expect(samples.values == [3, 4, 5])
        #expect(samples.latest == 5)
        #expect(samples.peak == 5)
    }
}
