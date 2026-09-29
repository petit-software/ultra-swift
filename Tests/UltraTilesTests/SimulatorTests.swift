import Foundation
import Testing
@testable import UltraCore
@testable import UltraLayout
@testable import UltraSimulator
@testable import UltraTiles

@Suite("Simulator pane record")
@MainActor
struct SimulatorRecordTests {
    private let root = URL(fileURLWithPath: "/tmp/project")
    private let phone = SimulatorDevice(udid: "D4136A4E-00B3-4D7A-9665-DAE6060AA8A1", name: "iPhone 17",
                                        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                        state: .booted)

    @Test("the record keeps the device's UDID, name and runtime, so a restore reopens the same device")
    func recordKeepsDevice() {
        let record = TileFactory.simulatorRecord(device: phone, root: root)
        #expect(record.kind == .simulator)
        #expect(record.command == phone.udid)
        #expect(record.title == "iPhone 17")
        #expect(record.subtitle == "iOS 27.0")
        #expect(record.icon == "iphone")
        #expect(record.cwd == root.path)
    }

    @Test("a tablet wears the tablet icon")
    func tabletIcon() {
        let pad = SimulatorDevice(udid: "X", name: "iPad mini (A17 Pro)", runtime: "r", state: .shutdown)
        #expect(TileFactory.simulatorRecord(device: pad, root: root).icon == "ipad")
    }

    @Test("an empty pane is called Simulator and has nothing to reopen")
    func emptyRecord() {
        let record = TileFactory.simulatorRecord(device: nil, root: root)
        #expect(record.title == "Simulator")
        #expect(record.subtitle == nil)
        #expect(record.command == nil)
    }

    @Test("a restored pane comes back on its device before the device list is in")
    @MainActor
    func restore() {
        let paneID = PaneID()
        let saved = TileFactory.simulatorRecord(device: phone, root: root)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        let content = factory.makeContent(for: paneID)
        #expect(content?.record.kind == .simulator)
        #expect(factory.simulatorSession(for: paneID)?.udid == phone.udid)
        #expect(factory.simulatorPanes() == [paneID])
        factory.release(paneID)
        #expect(factory.simulatorSession(for: paneID) == nil)
    }

    @Test("a zoomed pane saves its zoom and comes back at it; a fitted one saves nothing")
    @MainActor
    func zoomRoundTrip() {
        #expect(TileFactory.simulatorRecord(device: phone, root: root).tileState == nil)
        let paneID = PaneID()
        let saved = TileFactory.simulatorRecord(device: phone, zoom: 1.5, root: root)
        #expect(SimulatorPaneState.decode(saved.tileState).zoom == 1.5)
        let factory = TileFactory(context: .inert(root: root), restoring: [paneID: saved])
        _ = factory.makeContent(for: paneID)
        #expect(factory.simulatorSession(for: paneID)?.zoom == 1.5)
        factory.release(paneID)
    }

    @Test("zoom steps up and down through the stops, stops at the ends, and says Fit at 1")
    @MainActor
    func zoomSteps() {
        let session = SimulatorSession()
        #expect(session.isFitted && session.zoomLabel == "Fit")
        session.zoomIn()
        #expect(session.zoom == 1.25 && session.zoomLabel == "125%")
        session.zoomOut(); session.zoomOut()
        #expect(session.zoom == 0.75)
        for _ in 0..<20 { session.zoomOut() }
        #expect(session.zoom == 0.25 && !session.canZoomOut)
        for _ in 0..<20 { session.zoomIn() }
        #expect(session.zoom == 4 && !session.canZoomIn)
        session.zoomToFit()
        #expect(session.isFitted)
        // A saved value out of range is brought back into it.
        #expect(SimulatorSession(zoom: 40).zoom == 4)
    }

    @Test("a staged device wins over the restored one, and is consumed")
    @MainActor
    func staging() {
        let paneID = PaneID()
        let factory = TileFactory(context: .inert(root: root),
                                  restoring: [paneID: TileFactory.simulatorRecord(device: phone, root: root)])
        factory.stage(simulator: "OTHER")
        _ = factory.makeContent(for: paneID)
        #expect(factory.simulatorSession(for: paneID)?.udid == "OTHER")
        let second = PaneID()
        factory.stage(.simulator)
        _ = factory.makeContent(for: second)
        #expect(factory.simulatorSession(for: second)?.udid == nil)
    }

    @Test("choosing a device changes the saved record")
    @MainActor
    func choosingUpdatesRecord() {
        let paneID = PaneID()
        let factory = TileFactory(context: .inert(root: root), restoring: [:])
        factory.stage(.simulator)
        _ = factory.makeContent(for: paneID)
        var changed: PaneRecord?
        factory.onRecordChange = { _, record in changed = record }
        factory.simulatorSession(for: paneID)?.choose(phone)
        #expect(changed?.command == phone.udid)
        #expect(changed?.title == "iPhone 17")
    }

    @Test("the kind round-trips through the workspace document")
    func documentRoundTrip() throws {
        let record = TileFactory.simulatorRecord(device: phone, root: root)
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(PaneRecord.self, from: data)
        #expect(back == record)
    }
}
