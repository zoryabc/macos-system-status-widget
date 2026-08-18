import AppKit
import Foundation

/// 绘制 SystemWidget 的应用图标并生成 .icns。
/// 用法: swiftc make-icon.swift && make-icon <输出路径>.icns

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let corner = side * 0.2237
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    path.addClip()

    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.56, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.66, alpha: 1),
    ])!
    bg.draw(in: rect, angle: -90)

    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    gloss.draw(in: NSRect(x: 0, y: side * 0.52, width: side, height: side * 0.48), angle: -90)

    let c = NSPoint(x: side / 2, y: side / 2)
    let ringR = side * 0.30
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ringR, y: c.y - ringR,
                                           width: ringR * 2, height: ringR * 2))
    ring.lineWidth = side * 0.045
    NSColor.white.withAlphaComponent(0.95).setStroke()
    ring.stroke()

    let arcR = ringR - side * 0.07
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: arcR, startAngle: 120, endAngle: 355, clockwise: true)
    arc.lineWidth = side * 0.018
    NSColor.white.withAlphaComponent(0.35).setStroke()
    arc.stroke()

    let needle = NSBezierPath()
    needle.move(to: c)
    needle.line(to: NSPoint(x: c.x + ringR * 0.62, y: c.y + ringR * 0.62))
    needle.lineWidth = side * 0.05
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - side * 0.07, y: c.y - side * 0.07,
                                width: side * 0.14, height: side * 0.14)).fill()
    NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - side * 0.038, y: c.y - side * 0.038,
                                width: side * 0.076, height: side * 0.076)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode PNG")
    }
    try data.write(to: URL(fileURLWithPath: path))
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.icns>\n".utf8))
    exit(2)
}

let outPath = CommandLine.arguments[1]
let iconsetDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("SystemWidget.iconset")
try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in entries {
    let path = (iconsetDir as NSString).appendingPathComponent(name)
    try writePNG(drawIcon(pixels: pixels), to: path)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir, "-o", outPath]
iconutil.standardOutput = FileHandle.nullDevice
iconutil.standardError = FileHandle.nullDevice
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(atPath: iconsetDir)
print(outPath)
