import AppKit
import Foundation

/// 生成 DMG 窗口的背景图（安装引导）。
/// 用法: swiftc make-dmg-background.swift && make-dmg-background <输出路径>.png

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background <output.png>\n".utf8))
    exit(2)
}

let outPath = CommandLine.arguments[1]
let W: CGFloat = 660
let H: CGFloat = 420
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: W, height: H)
let bg = NSGradient(colors: [
    NSColor(calibratedWhite: 0.17, alpha: 1),
    NSColor(calibratedWhite: 0.075, alpha: 1),
])!
bg.draw(in: rect, angle: -90)

let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.95, alpha: 0.30),
    NSColor.clear,
])!
glow.draw(in: NSRect(x: W * 0.15, y: H * 0.25, width: W * 0.70, height: H * 0.75),
          relativeCenterPosition: NSPoint(x: 0.5, y: 0.5))

func draw(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attrs)
    let size = string.size()
    string.draw(at: NSPoint(x: (W - size.width) / 2, y: y))
}

draw("SystemWidget", font: .boldSystemFont(ofSize: 46), color: .white, y: H - 118)
draw("拖到 Applications 文件夹即可安装",
     font: .systemFont(ofSize: 19),
     color: NSColor(calibratedWhite: 0.82, alpha: 1),
     y: H - 158)
draw("Drag into the Applications folder to install",
     font: .systemFont(ofSize: 13),
     color: NSColor(calibratedWhite: 0.62, alpha: 1),
     y: H - 188)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print(outPath)
