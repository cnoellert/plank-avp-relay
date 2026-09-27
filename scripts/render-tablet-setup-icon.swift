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
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let raster = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space,
                                 bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast
                                                   : CGImageAlphaInfo.noneSkipLast).rawValue)
    else { fatalError("Invalid icon source or raster context") }
    // Core Graphics needs a supported 32-bit RGB layout even for the opaque
    // background; a tightly packed 24-bit AppKit bitmap cannot be drawn into.
    let context = NSGraphicsContext(cgContext: raster, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
               from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = raster.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    else { fatalError("Icon export failed") }
    let destination = assets.appendingPathComponent(
        "AppIcon.solidimagestack/\(layer).solidimagestacklayer/Content.imageset/\(name).png")
    try png.write(to: destination, options: .atomic)
}
