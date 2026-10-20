import CoreGraphics
import Foundation

/// What kind of hardware a device type is, as far as its enclosure goes. Decides the back
/// of the device — where its cameras are — its thickness, and which finishes it comes in.
///
/// From the device type identifier, which names the model: `iPhone-17-Pro`, `iPad-mini-
/// A17-Pro`. Xcode's own chrome cannot say — it draws one body for a whole generation —
/// which is why the family is read from the name and not from the chrome bundle.
public enum DeviceFamily: String, Sendable, CaseIterable {
    /// Pro iPhones: a full-width camera plateau with three lenses.
    case iPhonePro
    /// The plain iPhone of a generation: two lenses in a pill.
    case iPhone
    /// iPhone Air: a thin slab with one lens in a bar across the top.
    case iPhoneAir
    /// The e models: one lens, no bump to speak of.
    case iPhoneE
    /// An iPhone with a home button: the SE and everything before Face ID.
    case iPhoneHome
    /// iPhone Duo, folded onto its cover screen.
    case iPhoneDuo
    case iPad
    case iPadPro
    case watch
    case watchUltra
    /// Anything else — a TV — which keeps Xcode's own artwork.
    case other

    public static func of(deviceType: String) -> DeviceFamily {
        let model = deviceType.split(separator: ".").last.map(String.init) ?? deviceType
        let name = model.lowercased()
        if name.contains("watch") { return name.contains("ultra") ? .watchUltra : .watch }
        // "iPad-Pro-11-inch", not "iPad-mini-A17-Pro": the chip is Pro, the iPad is not.
        if name.contains("ipad") { return name.contains("ipad-pro") ? .iPadPro : .iPad }
        if name.contains("ipod") { return .iPhoneHome }
        guard name.contains("iphone") else { return .other }
        if name.contains("duo") { return .iPhoneDuo }
        if name.contains("air") { return .iPhoneAir }
        if name.contains("-se") || name.hasPrefix("iphone-8") || name.hasPrefix("iphone-7")
            || name.hasPrefix("iphone-6") { return .iPhoneHome }
        if name.range(of: #"iphone-\d+e\b"#, options: .regularExpression) != nil { return .iPhoneE }
        if name.contains("pro") { return .iPhonePro }
        return .iPhone
    }

    /// The model's generation: 17 for `iPhone-17-Pro`, 11 for `Apple-Watch-Series-11-46mm`,
    /// nil for a name with no number in that place (`iPhone-Air`, `iPad-mini-A17-Pro`).
    static func generation(of deviceType: String) -> Int? {
        let model = deviceType.split(separator: ".").last.map(String.init) ?? deviceType
        let patterns = [#"^iPhone-(\d+)"#, #"Series-(\d+)"#, #"Ultra-(\d+)"#, #"^iPad-(\d+)"#]
        for pattern in patterns {
            if let match = model.range(of: pattern, options: .regularExpression) {
                let digits = model[match].filter(\.isNumber)
                return Int(digits)
            }
        }
        return nil
    }

    /// Whether the back is glass, which is lighter and glossier than the rail, or the same
    /// metal as the rail all the way round.
    var hasGlassBack: Bool {
        switch self {
        case .iPhonePro, .iPhone, .iPhoneAir, .iPhoneE, .iPhoneHome, .iPhoneDuo: true
        case .iPad, .iPadPro, .watch, .watchUltra, .other: false
        }
    }

    /// How much of the body shows round the glass, as a fraction of its width. A touch
    /// wider than the hardware's — about a millimetre on a phone, which at pane size is a
    /// hairline — so the finish reads as a colour and not as an outline.
    var railRatio: CGFloat {
        switch self {
        case .iPhonePro, .iPhone, .iPhoneE, .iPhoneHome, .iPhoneDuo: 0.018
        case .iPhoneAir: 0.015
        case .iPad, .iPadPro: 0.009
        case .watch: 0.03
        case .watchUltra: 0.04
        case .other: 0.01
        }
    }
}

/// A colour in sRGB, 0 to 1.
public struct DeviceColor: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    /// `#F2731E`.
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
    }

    /// Toward white (positive) or black (negative), by a fraction.
    public func shaded(_ amount: Double) -> DeviceColor {
        let target = amount >= 0 ? 1.0 : 0.0
        let t = min(1, abs(amount))
        return DeviceColor(red: red + (target - red) * t, green: green + (target - green) * t,
                           blue: blue + (target - blue) * t)
    }

    /// Multiplied, for lighting: 1 is the colour itself, less is in shadow.
    public func lit(_ factor: Double) -> DeviceColor {
        DeviceColor(red: min(1, red * factor), green: min(1, green * factor), blue: min(1, blue * factor))
    }

    /// How light the colour reads, 0 to 1.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// One of the finishes a device is sold in: the colour of its rail and its back.
///
/// Apple's own names, so the picker says "Cosmic Orange" rather than "orange". The
/// colours are the finishes as they read in daylight, not Apple's marketing swatches,
/// which are lit for a product page.
public struct DeviceFinish: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var rail: DeviceColor
    /// The back, when it is not simply the rail's colour: glass is lighter than the metal
    /// round it, and a two-tone device has its own.
    public var backOverride: DeviceColor?
    /// The accent a model wears on one button — the Ultra's orange action button.
    public var accent: DeviceColor?

    public init(_ id: String, _ name: String, rail: UInt32, back: UInt32? = nil, accent: UInt32? = nil) {
        self.id = id
        self.name = name
        self.rail = DeviceColor(hex: rail)
        self.backOverride = back.map(DeviceColor.init(hex:))
        self.accent = accent.map(DeviceColor.init(hex:))
    }

    /// The back's colour for a family: the override, else glass a shade lighter than the
    /// rail, else the rail.
    public func back(for family: DeviceFamily) -> DeviceColor {
        if let backOverride { return backOverride }
        return family.hasGlassBack ? rail.shaded(rail.luminance > 0.5 ? 0.06 : 0.10) : rail
    }

    // MARK: - Palettes

    /// The finishes a device type comes in, the one a fresh pane shows first. Never empty.
    ///
    /// By generation, from the model's name. A model newer than this list — the device
    /// types Xcode ships ahead of the hardware — takes the newest palette of its family,
    /// which is the honest guess and says nothing wrong about a colour that exists.
    public static func palette(for deviceType: String) -> [DeviceFinish] {
        let family = DeviceFamily.of(deviceType: deviceType)
        let generation = DeviceFamily.generation(of: deviceType)
        let name = (deviceType.split(separator: ".").last.map(String.init) ?? deviceType).lowercased()
        switch family {
        case .iPhonePro:
            switch generation {
            case .some(...14):
                return [DeviceFinish("space-black", "Space Black", rail: 0x2F2F32),
                        DeviceFinish("deep-purple", "Deep Purple", rail: 0x5B5068),
                        DeviceFinish("gold", "Gold", rail: 0xE6D2B5),
                        DeviceFinish("silver", "Silver", rail: 0xE2E3E5)]
            case 15:
                return [DeviceFinish("natural-titanium", "Natural Titanium", rail: 0xB9B3A8),
                        DeviceFinish("blue-titanium", "Blue Titanium", rail: 0x3C4B5E),
                        DeviceFinish("white-titanium", "White Titanium", rail: 0xE7E6E2),
                        DeviceFinish("black-titanium", "Black Titanium", rail: 0x3A3A3C)]
            case 16:
                return [DeviceFinish("desert-titanium", "Desert Titanium", rail: 0xC7A98B),
                        DeviceFinish("natural-titanium", "Natural Titanium", rail: 0xB9B3A8),
                        DeviceFinish("white-titanium", "White Titanium", rail: 0xE7E6E2),
                        DeviceFinish("black-titanium", "Black Titanium", rail: 0x3A3A3C)]
            default:
                // iPhone 17 Pro, and whatever is newer until it is added here.
                return [DeviceFinish("cosmic-orange", "Cosmic Orange", rail: 0xE8702A, back: 0xF08A45),
                        DeviceFinish("deep-blue", "Deep Blue", rail: 0x1F2D4E, back: 0x2A3A60),
                        DeviceFinish("silver", "Silver", rail: 0xE3E4E6, back: 0xEEEFF1)]
            }
        case .iPhone:
            switch generation {
            case .some(...14):
                return [DeviceFinish("midnight", "Midnight", rail: 0x25262B),
                        DeviceFinish("starlight", "Starlight", rail: 0xECE6DC),
                        DeviceFinish("blue", "Blue", rail: 0xA7BDD4),
                        DeviceFinish("purple", "Purple", rail: 0xD3C6E1),
                        DeviceFinish("red", "(PRODUCT)RED", rail: 0xC0242C)]
            case 15:
                return [DeviceFinish("pink", "Pink", rail: 0xF3CBD5),
                        DeviceFinish("yellow", "Yellow", rail: 0xF1E8B8),
                        DeviceFinish("green", "Green", rail: 0xCADBC9),
                        DeviceFinish("blue", "Blue", rail: 0xC9D6E2),
                        DeviceFinish("black", "Black", rail: 0x303236)]
            case 16:
                return [DeviceFinish("ultramarine", "Ultramarine", rail: 0x4D63CF, back: 0x6A7FE0),
                        DeviceFinish("teal", "Teal", rail: 0x4F9196, back: 0x66A9AE),
                        DeviceFinish("pink", "Pink", rail: 0xF0B5C6, back: 0xF7C9D6),
                        DeviceFinish("white", "White", rail: 0xF2F2F0),
                        DeviceFinish("black", "Black", rail: 0x2A2A2C)]
            default:
                return [DeviceFinish("lavender", "Lavender", rail: 0xC6BBE4, back: 0xD4CCEC),
                        DeviceFinish("mist-blue", "Mist Blue", rail: 0xADC6DE, back: 0xBFD4E8),
                        DeviceFinish("sage", "Sage", rail: 0xA6B49C, back: 0xB6C3AD),
                        DeviceFinish("white", "White", rail: 0xF3F3F1),
                        DeviceFinish("black", "Black", rail: 0x2B2B2E)]
            }
        case .iPhoneAir:
            return [DeviceFinish("sky-blue", "Sky Blue", rail: 0xC9DDEE, back: 0xD8E7F3),
                    DeviceFinish("light-gold", "Light Gold", rail: 0xE8DAC1, back: 0xF0E6D2),
                    DeviceFinish("cloud-white", "Cloud White", rail: 0xF4F3F0),
                    DeviceFinish("space-black", "Space Black", rail: 0x232326)]
        case .iPhoneE:
            return [DeviceFinish("white", "White", rail: 0xF2F2F0),
                    DeviceFinish("black", "Black", rail: 0x262628)]
        case .iPhoneHome:
            return [DeviceFinish("midnight", "Midnight", rail: 0x222326),
                    DeviceFinish("starlight", "Starlight", rail: 0xEDE8E0),
                    DeviceFinish("red", "(PRODUCT)RED", rail: 0xBB262D)]
        case .iPhoneDuo:
            // Not announced when this was written: the Pro finishes until it is.
            return [DeviceFinish("cosmic-orange", "Cosmic Orange", rail: 0xE8702A, back: 0xF08A45),
                    DeviceFinish("deep-blue", "Deep Blue", rail: 0x1F2D4E, back: 0x2A3A60),
                    DeviceFinish("silver", "Silver", rail: 0xE3E4E6, back: 0xEEEFF1)]
        case .iPadPro:
            return [DeviceFinish("space-black", "Space Black", rail: 0x3B3B3D),
                    DeviceFinish("silver", "Silver", rail: 0xDDDDDE)]
        case .iPad:
            if name.contains("air") || name.contains("mini") {
                return [DeviceFinish("space-gray", "Space Gray", rail: 0x6B6B70),
                        DeviceFinish("starlight", "Starlight", rail: 0xE8E3D9),
                        DeviceFinish("blue", "Blue", rail: 0xB4C4D6),
                        DeviceFinish("purple", "Purple", rail: 0xC8C0DD)]
            }
            return [DeviceFinish("blue", "Blue", rail: 0x6C98C8),
                    DeviceFinish("pink", "Pink", rail: 0xE6A3B3),
                    DeviceFinish("yellow", "Yellow", rail: 0xEFD56C),
                    DeviceFinish("silver", "Silver", rail: 0xDCDCDE)]
        case .watch:
            return [DeviceFinish("jet-black", "Jet Black", rail: 0x1E1E20),
                    DeviceFinish("rose-gold", "Rose Gold", rail: 0xE0B7A8),
                    DeviceFinish("silver", "Silver", rail: 0xD9D9DB),
                    DeviceFinish("space-gray", "Space Gray", rail: 0x5E5E62)]
        case .watchUltra:
            return [DeviceFinish("natural-titanium", "Natural Titanium", rail: 0xB5B1A9, accent: 0xF0601A),
                    DeviceFinish("black-titanium", "Black Titanium", rail: 0x2E2E30, accent: 0xF0601A)]
        case .other:
            return [DeviceFinish("graphite", "Graphite", rail: 0x3A3A3C)]
        }
    }

    /// The finish with this id for the device type, or the first when the id is nil or
    /// names a finish the model does not come in — a pane restored onto another device.
    public static func finish(_ id: String?, for deviceType: String) -> DeviceFinish {
        let palette = palette(for: deviceType)
        return id.flatMap { id in palette.first { $0.id == id } } ?? palette[0]
    }
}
