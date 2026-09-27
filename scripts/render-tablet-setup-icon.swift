// SPDX-License-Identifier: GPL-3.0-or-later
// Build-time vector-to-raster export. No window, screen capture or permission.
import AppKit

guard CommandLine.arguments.count == 3 else { fatalError("Expected artwork and generated asset directories") }
let artwork = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for layer in ["Front", "Back"] {
    let name = layer.lowercased()
    let alpha = layer == "Front"
    guard let image = NSImage(contentsOf: artwork.appendingPathComponent("\(name).svg")),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                        bitsPerSample: 8, samplesPerPixel: alpha ? 4 : 3,
                                        hasAlpha: alpha, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Invalid icon source") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
               from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon export failed") }
    let destination = assets.appendingPathComponent(
        "AppIcon.solidimagestack/\(layer).solidimagestacklayer/Content.imageset/\(name).png")
    try png.write(to: destination, options: .atomic)
}
