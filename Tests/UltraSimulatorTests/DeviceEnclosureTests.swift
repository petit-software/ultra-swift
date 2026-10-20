import AppKit
import Testing
@testable import UltraSimulator

/// Which hardware a device type is, and what it comes in.
@Suite("Device family and finish")
struct DeviceFinishTests {
    private let prefix = "com.apple.CoreSimulator.SimDeviceType."

    @Test("the family is read from the model's name")
    func family() {
        let cases: [(String, DeviceFamily)] = [
            ("iPhone-17-Pro", .iPhonePro), ("iPhone-18-Pro-Max", .iPhonePro), ("iPhone-17", .iPhone),
            ("iPhone-16-Plus", .iPhone), ("iPhone-Air", .iPhoneAir), ("iPhone-16e", .iPhoneE),
            ("iPhone-17e", .iPhoneE), ("iPhone-SE-3rd-generation", .iPhoneHome), ("iPhone-8", .iPhoneHome),
            ("iPod-touch--7th-generation-", .iPhoneHome), ("iPhone-Duo", .iPhoneDuo),
            ("iPad-mini-A17-Pro", .iPad), ("iPad-Air-13-inch-M4", .iPad), ("iPad-A16", .iPad),
            ("iPad-Pro-11-inch-4th-generation-8GB", .iPadPro),
            ("Apple-Watch-Series-11-46mm", .watch), ("Apple-Watch-Ultra-4-49mm", .watchUltra),
            ("Apple-TV-4K-3rd-generation-4K", .other),
        ]
        for (name, expected) in cases {
            #expect(DeviceFamily.of(deviceType: prefix + name) == expected, Comment(rawValue: name))
        }
    }

    @Test("the generation is the number after the family's name")
    func generation() {
        #expect(DeviceFamily.generation(of: prefix + "iPhone-17-Pro") == 17)
        #expect(DeviceFamily.generation(of: prefix + "iPhone-16e") == 16)
        #expect(DeviceFamily.generation(of: prefix + "Apple-Watch-Series-11-46mm") == 11)
        #expect(DeviceFamily.generation(of: prefix + "Apple-Watch-Ultra-4-49mm") == 4)
        #expect(DeviceFamily.generation(of: prefix + "iPhone-Air") == nil)
        #expect(DeviceFamily.generation(of: prefix + "iPad-mini-A17-Pro") == nil)
    }

    @Test("every family has a palette, the real names, and a device newer than the list takes the newest")
    func palettes() {
        for family in DeviceFamily.allCases {
            let sample: String = switch family {
            case .iPhonePro: "iPhone-17-Pro"
            case .iPhone: "iPhone-17"
            case .iPhoneAir: "iPhone-Air"
            case .iPhoneE: "iPhone-16e"
            case .iPhoneHome: "iPhone-SE-3rd-generation"
            case .iPhoneDuo: "iPhone-Duo"
            case .iPad: "iPad-mini-A17-Pro"
            case .iPadPro: "iPad-Pro-11-inch-4th-generation-8GB"
            case .watch: "Apple-Watch-Series-11-46mm"
            case .watchUltra: "Apple-Watch-Ultra-4-49mm"
            case .other: "Apple-TV-4K-3rd-generation-4K"
            }
            #expect(!DeviceFinish.palette(for: prefix + sample).isEmpty, Comment(rawValue: sample))
        }
        #expect(DeviceFinish.palette(for: prefix + "iPhone-17-Pro").map(\.name) == ["Cosmic Orange", "Deep Blue", "Silver"])
        #expect(DeviceFinish.palette(for: prefix + "iPhone-16").map(\.name).first == "Ultramarine")
        #expect(DeviceFinish.palette(for: prefix + "iPhone-15-Pro").map(\.name).first == "Natural Titanium")
        #expect(DeviceFinish.palette(for: prefix + "iPhone-18-Pro").map(\.name) ==
                DeviceFinish.palette(for: prefix + "iPhone-17-Pro").map(\.name))
        #expect(DeviceFinish.palette(for: prefix + "Apple-Watch-Ultra-4-49mm").allSatisfy { $0.accent != nil })
    }

    @Test("a finish is found by id, and an unknown or missing id is the model's first")
    func lookup() {
        let type = prefix + "iPhone-17"
        #expect(DeviceFinish.finish("sage", for: type).name == "Sage")
        #expect(DeviceFinish.finish(nil, for: type).name == "Lavender")
        #expect(DeviceFinish.finish("cosmic-orange", for: type).name == "Lavender")
    }

    @Test("glass backs are lighter than their rail; metal ones are the rail")
    func backs() {
        let black = DeviceFinish("black", "Black", rail: 0x2B2B2E)
        #expect(black.back(for: .iPhone).luminance > black.rail.luminance)
        #expect(black.back(for: .iPad) == black.rail)
        let orange = DeviceFinish("cosmic-orange", "Cosmic Orange", rail: 0xE8702A, back: 0xF08A45)
        #expect(orange.back(for: .iPhonePro) == DeviceColor(hex: 0xF08A45))
    }
}

/// The soft body drawn from Xcode's geometry.
@Suite("Device enclosure")
@MainActor
struct DeviceEnclosureTests {

    @Test("the drawn front wears the finish on its body and black glass round the screen")
    func drawnFront() throws {
        let geometry = DeviceChrome.geometry(screen: CGSize(width: 402, height: 874),
                                             sizing: DeviceChrome.Insets(top: 18, left: 18, bottom: 18, right: 18),
                                             buttons: [])
        let orange = DeviceFinish("cosmic-orange", "Cosmic Orange", rail: 0xE8702A, back: 0xF08A45)
        let spec = DeviceEnclosure.Spec(family: .iPhonePro, finish: orange, size: geometry.size, body: geometry.body,
                                        screen: geometry.screen, cornerRadius: 60)
        let front = try #require(DeviceEnclosure.front(spec, scale: 1))
        let rep = NSBitmapImageRep(cgImage: front)
        let body = try #require(rep.colorAt(x: 2, y: Int(geometry.size.height / 2))?.usingColorSpace(.sRGB))
        #expect(body.redComponent > body.greenComponent && body.greenComponent > body.blueComponent)
        #expect(body.alphaComponent > 0.95)
        let glass = try #require(rep.colorAt(x: 10, y: Int(geometry.size.height / 2))?.usingColorSpace(.sRGB))
        #expect(glass.redComponent < 0.15 && glass.greenComponent < 0.15 && glass.blueComponent < 0.15)
        // Outside the rounded corner there is nothing.
        let corner = try #require(rep.colorAt(x: 1, y: 1))
        #expect(corner.alphaComponent < 0.05)
    }

    @Test("Xcode's geometry gets this drawing for a known family, without room for buttons")
    func loadedChrome() throws {
        let type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        guard DeviceProfile.load(deviceType: type) != nil else { return }
        let orange = try #require(DeviceChrome.load(deviceType: type))
        #expect(orange.family == .iPhonePro)
        #expect(orange.finish?.id == "cosmic-orange")
        #expect(orange.body == CGRect(origin: .zero, size: orange.size), "the body is the whole picture")
        let silver = try #require(DeviceChrome.load(deviceType: type, finish: DeviceFinish.finish("silver", for: type)))
        #expect(silver.finish?.id == "silver")
        #expect(silver.image !== orange.image)
        #expect(silver.screen == orange.screen)
    }
}
