import AppKit

/// Fit an iOS-shaped icon export onto the macOS app-icon grid.
///
/// Icon Composer's iOS exports fill the whole 1024pt canvas, because iOS masks the icon
/// itself. macOS does not mask: it expects the artwork pre-shaped and INSET, with the body
/// occupying 824 of 1024 and the surrounding margin left transparent for the shadow the
/// system draws. Handing macOS a full-bleed iOS export makes the icon render oversized next
/// to every other app, with its own baked shadow crowding the system's — which is what
/// "odd edges" looks like.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon-master <in.png> <out.png>\n".utf8))
    exit(2)
}

let canvas = 1024.0
/// Apple's macOS icon grid: the rounded body is 824 wide inside a 1024 canvas.
let body = 824.0

guard let source = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("cannot read \(arguments[1])\n".utf8))
    exit(1)
}

let output = NSImage(size: NSSize(width: canvas, height: canvas))
output.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let inset = (canvas - body) / 2
source.draw(in: NSRect(x: inset, y: inset, width: body, height: body),
            from: .zero, operation: .sourceOver, fraction: 1.0)
output.unlockFocus()

guard let tiff = output.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: arguments[2]))
print("icon master: \(Int(body))pt body on a \(Int(canvas))pt canvas")
