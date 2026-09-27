import Foundation
import Testing
@testable import UltraSimulator

@Suite("Simulator device list")
struct SimulatorDeviceListTests {

    /// The shape `xcrun simctl list devices --json` prints, trimmed to what the parser reads.
    private let fixture = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
          { "udid" : "D4136A4E-00B3-4D7A-9665-DAE6060AA8A1", "name" : "iPhone 17",
            "state" : "Booted", "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            "dataPath" : "/x", "logPath" : "/y" },
          { "udid" : "23001BED-6A51-46A6-BFBF-F59EC7737168", "name" : "iPad mini (A17 Pro)",
            "state" : "Shutdown", "isAvailable" : true },
          { "udid" : "5C5B25D6-51CB-49C2-91B9-60036413682E", "name" : "Demo data",
            "state" : "Shutdown", "isAvailable" : true }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          { "udid" : "ACA24C5A-B36F-4DD4-8095-C24D09218C02", "name" : "iPhone 17",
            "state" : "Shutdown", "isAvailable" : false,
            "availabilityError" : "runtime profile not found" }
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0" : [ ]
      }
    }
    """

    @Test("devices decode with their runtime, state and availability")
    func decodes() throws {
        let devices = try SimulatorDeviceList.parse(Data(fixture.utf8))
        #expect(devices.count == 4)
        let phone = try #require(devices.first { $0.udid == "D4136A4E-00B3-4D7A-9665-DAE6060AA8A1" })
        #expect(phone.name == "iPhone 17")
        #expect(phone.state == .booted)
        #expect(phone.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(phone.runtimeName == "iOS 27.0")
        #expect(phone.isAvailable)
        let old = try #require(devices.first { $0.udid == "ACA24C5A-B36F-4DD4-8095-C24D09218C02" })
        #expect(!old.isAvailable)
        #expect(old.runtimeName == "iOS 26.5")
    }

    @Test("booted devices lead, then the newest runtime, then names")
    func ordering() throws {
        let devices = try SimulatorDeviceList.parse(Data(fixture.utf8))
        #expect(devices.map(\.name) == ["iPhone 17", "Demo data", "iPad mini (A17 Pro)", "iPhone 17"])
        #expect(devices[0].state == .booted)
        #expect(devices.last?.isAvailable == false)
    }

    @Test("grouping keeps one section per runtime, newest first")
    func grouping() throws {
        let devices = try SimulatorDeviceList.parse(Data(fixture.utf8))
        let groups = SimulatorDeviceList.grouped(devices)
        #expect(groups.map(\.runtime) == ["com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                          "com.apple.CoreSimulator.SimRuntime.iOS-26-5"])
        #expect(groups[0].devices.count == 3)
    }

    @Test("a UDID finds its device exactly; a name prefers the booted one")
    func finding() throws {
        let devices = try SimulatorDeviceList.parse(Data(fixture.utf8))
        #expect(SimulatorDeviceList.find("aca24c5a-b36f-4dd4-8095-c24d09218c02", in: devices)?.runtimeName == "iOS 26.5")
        #expect(SimulatorDeviceList.find("iphone 17", in: devices)?.state == .booted)
        #expect(SimulatorDeviceList.find("iPad mini (A17 Pro)", in: devices)?.isTablet == true)
        #expect(SimulatorDeviceList.find("Pixel 9", in: devices) == nil)
    }

    @Test("an unknown state is kept rather than dropped")
    func unknownState() throws {
        let json = #"{"devices":{"r":[{"udid":"A","name":"X","state":"Creating"}]}}"#
        let devices = try SimulatorDeviceList.parse(Data(json.utf8))
        #expect(devices.first?.state == .unknown)
        #expect(SimulatorDevice.runtimeName(of: "r") == "r")
    }
}
