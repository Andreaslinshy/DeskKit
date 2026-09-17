#!/usr/bin/env swift
// Reproducible vector artwork for the Finder installer. Coordinates are in points.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let output = URL(fileURLWithPath: arguments.first ?? "Artwork/Installer", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width: CGFloat = 760
let height: CGFloat = 560

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func label(_ text: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight,
           tint: NSColor, centered: Bool = false, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    (text as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: tint,
        .paragraphStyle: paragraph, .kern: tracking
    ])
}
func bitmap(size: NSSize, scale: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Draw in pixel space first. Setting rep.size here makes AppKit apply
    // the Retina scale before our explicit transform, scaling the artwork twice.
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    let context = graphics.cgContext
    context.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    rep.size = size
    return rep
}
func background(_ context: CGContext) {
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    color(0xF5F8FC).setFill(); bounds.fill()
    let space = CGColorSpaceCreateDeviceRGB()
    for (hex, center, radius) in [(UInt32(0x9DEBEF), CGPoint(x: 20, y: 0), CGFloat(510)),
                                  (UInt32(0xBCCAFF), CGPoint(x: 740, y: 565), CGFloat(520))] {
        let gradient = CGGradient(colorsSpace: space,
            colors: [color(hex, 0.52).cgColor, color(hex, 0).cgColor] as CFArray,
            locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius, options: [])
    }
    for offset in [CGFloat(0), 25] {
        let curve = NSBezierPath()
        curve.move(to: NSPoint(x: -40, y: 155 + offset))
        curve.curve(to: NSPoint(x: 800, y: 15 + offset),
                    controlPoint1: NSPoint(x: 220, y: 240 + offset),
                    controlPoint2: NSPoint(x: 520, y: -70 + offset))
        color(0xFFFFFF, 0.45).setStroke(); curve.lineWidth = 1; curve.stroke()
    }
    label("DESKKIT", NSRect(x: 0, y: 37, width: width, height: 19), size: 10,
          weight: .semibold, tint: color(0x4695A0), centered: true, tracking: 3)
    label("安装 DeskKit", NSRect(x: 0, y: 69, width: width, height: 46), size: 32,
          weight: .semibold, tint: color(0x1B3143), centered: true)
    label("将左侧应用拖入右侧 Applications 文件夹", NSRect(x: 0, y: 121, width: width, height: 25),
          size: 14, weight: .regular, tint: color(0x6F8190), centered: true)
    for x in [CGFloat(84), 452] {
        let card = NSBezierPath(roundedRect: NSRect(x: x, y: 181, width: 224, height: 189), xRadius: 28, yRadius: 28)
        color(0xFFFFFF, 0.63).setFill(); card.fill()
        color(0xFFFFFF, 0.93).setStroke(); card.lineWidth = 1.5; card.stroke()
    }
    for (x, alpha) in [(CGFloat(337), CGFloat(0.22)), (351, 0.45)] {
        color(0x29ABB9, alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 251, width: 6, height: 6)).fill()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 370, y: 254)); arrow.line(to: NSPoint(x: 416, y: 254))
    arrow.move(to: NSPoint(x: 401, y: 239)); arrow.line(to: NSPoint(x: 416, y: 254)); arrow.line(to: NSPoint(x: 401, y: 269))
    color(0x29ABB9).setStroke(); arrow.lineWidth = 4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    color(0xA7BAC9, 0.3).setFill(); NSRect(x: 72, y: 406, width: 616, height: 1).fill()
    label("三个参考样例，随应用提供", NSRect(x: 76, y: 440, width: 450, height: 24),
          size: 15, weight: .medium, tint: color(0x425A6D))
    label("首次启动自动载入 · 默认停用", NSRect(x: 76, y: 470, width: 450, height: 22),
          size: 12, weight: .regular, tint: color(0x8293A0))
}
for scale in [1, 2] {
    let rep = bitmap(size: NSSize(width: width, height: height), scale: scale, draw: background)
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
// A compact supplemental folder icon on the same 112-point Finder icon grid.
let folder = NSImage(size: NSSize(width: 128, height: 128))
let folderRep = bitmap(size: NSSize(width: 128, height: 128), scale: 4) { _ in
    let tab = NSBezierPath(roundedRect: NSRect(x: 40, y: 44, width: 23, height: 12), xRadius: 4, yRadius: 4)
    color(0x94CCD4).setFill(); tab.fill()
    let body = NSBezierPath(roundedRect: NSRect(x: 40, y: 51, width: 48, height: 33), xRadius: 6, yRadius: 6)
    color(0xD2EAEF).setFill(); body.fill()
    color(0x83BEC9).setStroke(); body.lineWidth = 1; body.stroke()
    let lines = NSBezierPath()
    for y in [CGFloat(62), 69] { lines.move(to: NSPoint(x: 53, y: y)); lines.line(to: NSPoint(x: 75, y: y)) }
    color(0x5C99A8).setStroke(); lines.lineWidth = 2; lines.lineCapStyle = .round; lines.stroke()
}
folder.addRepresentation(folderRep)
if arguments.count > 1 {
    guard NSWorkspace.shared.setIcon(folder, forFile: arguments[1], options: []) else {
        fatalError("Cannot set the supplemental folder icon")
    }
}
print("Installer artwork generated at \(output.path)")
