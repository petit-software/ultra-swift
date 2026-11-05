import AppKit
import Testing
@testable import UltraTiles

@Suite("Ultra pane: SIN SIN")
@MainActor
struct UltraPaneTests {
    @Test("a frame fills every cell of the grid it is asked for")
    func fillsTheGrid() {
        let runner = AsciiRunner(program: SinSin())
        runner.step(deltaMS: 0, cols: 40, rows: 12)
        #expect(runner.cells.count == 480)
        #expect(runner.cells.allSatisfy { $0.weight != nil })
        // Both halves of the checker show up: the light pattern's letters and the bold one's digits.
        let chars = Set(runner.cells.map(\.char))
        #expect(chars.contains("0") || chars.contains("1"))
        #expect(chars.contains("a") || chars.contains("b") || chars.contains("c"))
    }

    @Test("the pattern moves with time")
    func animates() {
        let runner = AsciiRunner(program: SinSin())
        runner.step(deltaMS: 0, cols: 60, rows: 20)
        let first = runner.cells
        runner.step(deltaMS: 1500, cols: 60, rows: 20)
        #expect(runner.cells != first)
    }

    @Test("a new size starts on a clean grid of that size")
    func resizes() {
        let runner = AsciiRunner(program: SinSin())
        runner.step(deltaMS: 0, cols: 10, rows: 10)
        runner.step(deltaMS: 16, cols: 25, rows: 4)
        #expect(runner.cols == 25 && runner.rows == 4 && runner.cells.count == 100)
    }
}

@Suite("Ports: filter by address")
@MainActor
struct PortsAddressFilterTests {
    @Test("loopback covers every spelling of this Mac")
    func loopback() {
        for address in ["127.0.0.1", "127.0.1.1", "::1", "localhost"] {
            #expect(PortsAddressFilter.loopback.matches(address))
        }
        for address in ["*", "0.0.0.0", "192.168.1.4", "::"] {
            #expect(!PortsAddressFilter.loopback.matches(address))
        }
    }

    @Test("all interfaces covers lsof's * and the wildcard addresses")
    func anyInterface() {
        for address in ["*", "0.0.0.0", "::"] {
            #expect(PortsAddressFilter.anyInterface.matches(address))
        }
        #expect(!PortsAddressFilter.anyInterface.matches("127.0.0.1"))
    }

    @Test("the model shows only what the filter lets through")
    func visiblePorts() {
        let output = "p100\ncnode\nn127.0.0.1:3000\np200\ncpostgres\nn*:5432\np300\ncredis\nn[::1]:6379\n"
        let model = PortsModel()
        // Fed through the parser the model itself uses.
        let parsed = PortsModel.parse(output)
        #expect(parsed.map(\.address) == ["127.0.0.1", "*", "::1"])
        model.addressFilter = .loopback
        #expect(parsed.filter { model.addressFilter.matches($0.address) }.map(\.port) == [3000, 6379])
        model.addressFilter = .exact("*")
        #expect(parsed.filter { model.addressFilter.matches($0.address) }.map(\.port) == [5432])
    }

    @Test("the filter round-trips through the pane's record, and All writes nothing")
    func persistence() {
        #expect(PortsAddressFilter.all.encoded == nil)
        #expect(PortsAddressFilter.decode(nil) == .all)
        for filter in [PortsAddressFilter.loopback, .anyInterface, .exact("10.0.0.2")] {
            #expect(PortsAddressFilter.decode(filter.encoded) == filter)
        }
    }

    @Test("a change of filter is reported once, for the record to follow")
    func reportsChanges() {
        let model = PortsModel()
        var seen: [PortsAddressFilter] = []
        model.onFilterChange = { seen.append($0) }
        model.addressFilter = .loopback
        model.addressFilter = .loopback
        model.addressFilter = .all
        #expect(seen == [.loopback, .all])
    }
}
