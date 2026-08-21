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
        .executable(name: "Ultra", targets: ["Ultra"]),
    ],
    dependencies: [
        // Xterm/VT100 emulation in Swift, with a headless `Terminal` engine kept separate
        // from the AppKit view — that separation is what makes shell panes previewable and
        // leaves a path to our own renderer. See docs/00-OVERVIEW.md.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
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
        .executableTarget(name: "Ultra", dependencies: ["UltraCanvas", "UltraCore", "UltraTerminal", "UltraLayout", "UltraDesign"]),
        .testTarget(name: "UltraLayoutTests", dependencies: ["UltraLayout"]),
        .testTarget(name: "UltraCanvasTests", dependencies: ["UltraCanvas", "UltraTerminal", "UltraLayout"]),
        .testTarget(name: "UltraCoreTests", dependencies: ["UltraCore", "UltraLayout"]),
        .testTarget(name: "UltraTerminalTests", dependencies: ["UltraTerminal"]),
    ]
)
