import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (filename, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                       bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot draw icon") }
    let s = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSColor(red: 0.10, green: 0.12, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: s * 0.22, yRadius: s * 0.22).fill()

    let mint = NSColor(red: 0.56, green: 0.82, blue: 0.73, alpha: 1)
    mint.setStroke()
    let border = NSBezierPath(roundedRect: NSRect(x: s * 0.245, y: s * 0.245,
                                                  width: s * 0.51, height: s * 0.51),
                              xRadius: s * 0.115, yRadius: s * 0.115)
    border.lineWidth = max(1, s * 0.025)
    border.stroke()

    mint.setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.355, y: s * 0.53,
                                    width: s * 0.29, height: max(1, s * 0.027)),
                 xRadius: s * 0.014, yRadius: s * 0.014).fill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.355, y: s * 0.43,
                                    width: s * 0.19, height: max(1, s * 0.027)),
                 xRadius: s * 0.014, yRadius: s * 0.014).fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot save icon") }
    try png.write(to: destination.appendingPathComponent(filename))
}

let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]
var payload = Data()
for (type, filename) in chunks {
    let png = try Data(contentsOf: destination.appendingPathComponent(filename))
    payload.append(Data(type.utf8))
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
    payload.append(png)
}
var icon = Data("icns".utf8)
var totalLength = UInt32(payload.count + 8).bigEndian
withUnsafeBytes(of: &totalLength) { icon.append(contentsOf: $0) }
icon.append(payload)
try icon.write(to: destination.deletingLastPathComponent().appendingPathComponent("ResearchDesk.icns"))
