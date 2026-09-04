// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ultra",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "UltraLayout", targets: ["UltraLayout"]),
        .library(name: "UltraDesign", targets: ["UltraDesign"]),
        .library(name: "UltraCore", targets: ["UltraCore"]),
        .library(name: "UltraTerminal", targets: ["UltraTerminal"]),
        .library(name: "UltraCanvas", targets: ["UltraCanvas"]),
        .library(name: "UltraChat", targets: ["UltraChat"]),
        .executable(name: "Ultra", targets: ["Ultra"]),
    ],
    dependencies: [
        // Xterm/VT100 emulation in Swift, with a headless `Terminal` engine kept separate
        // from the AppKit view — that separation is what makes shell panes previewable and
        // leaves a path to our own renderer. See docs/00-OVERVIEW.md.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // Updates. Sparkle is what notarized Mac apps outside the store use, and it already
        // owns the parts that are easy to get wrong: atomic replacement, a resumed or
        // corrupt download, and not installing over a running copy of itself.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure model + layout math. Deliberately depends on nothing of ours and
        // no UI framework — see docs/01-SPLIT-ENGINE.md.
        .target(name: "UltraLayout"),
        .target(name: "UltraDesign"),
        .target(name: "UltraCore", dependencies: ["UltraLayout"]),
        .target(name: "UltraTerminal",
                dependencies: ["UltraCore", "UltraDesign", "UltraLayout",
                               .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "UltraCanvas", dependencies: ["UltraLayout", "UltraDesign", "UltraCore"]),
        // Talking to language models: the four providers, the streams they answer with,
        // and the conversations on disk. Foundation only — no UI, nothing of ours — so
        // every provider is tested against a recorded transcript rather than a network.
        .target(name: "UltraChat"),
        // Every tile except Shell. SwiftUI views in hosting views, sharing one context —
        // see docs/03-TILES.md. Depends on no canvas type: a tile never knows about layout.
        .target(name: "UltraTiles", dependencies: ["UltraCore", "UltraDesign", "UltraLayout", "UltraChat"]),
        .executableTarget(name: "Ultra",
                          dependencies: ["UltraCanvas", "UltraCore", "UltraTerminal",
                                         "UltraTiles", "UltraLayout", "UltraDesign", "UltraChat",
                                         .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "UltraLayoutTests", dependencies: ["UltraLayout"]),
        .testTarget(name: "UltraDesignTests", dependencies: ["UltraDesign"]),
        .testTarget(name: "UltraCanvasTests", dependencies: ["UltraCanvas", "UltraTerminal", "UltraLayout", "UltraDesign"]),
        .testTarget(name: "UltraCoreTests", dependencies: ["UltraCore", "UltraLayout"]),
        .testTarget(name: "UltraTerminalTests", dependencies: ["UltraTerminal", "UltraLayout", "UltraDesign"]),
        .testTarget(name: "UltraTilesTests", dependencies: ["UltraTiles", "UltraCore"]),
        .testTarget(name: "UltraChatTests", dependencies: ["UltraChat"]),
    ]
)
