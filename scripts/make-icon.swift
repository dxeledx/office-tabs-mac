#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("用法：swift make-icon.swift <输出.iconset目录>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "OfficeTabs.Icon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    // 用统一的设计坐标绘制，在输出时缩放到 iconset 要求的实际像素。
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
    NSGradient(colors: [
        NSColor(srgbRed: 0.19, green: 0.43, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.27, green: 0.24, blue: 0.77, alpha: 1)
    ])!.draw(in: background, angle: -55)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 34
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    rounded(NSRect(x: 184, y: 242, width: 656, height: 548), radius: 58, color: .white)
    NSGraphicsContext.restoreGraphicsState()

    let mutedBlue = NSColor(srgbRed: 0.82, green: 0.88, blue: 0.99, alpha: 1)
    rounded(NSRect(x: 184, y: 640, width: 656, height: 150), radius: 58, color: mutedBlue)
    rounded(NSRect(x: 184, y: 640, width: 656, height: 72), radius: 0, color: mutedBlue)
    rounded(NSRect(x: 215, y: 649, width: 224, height: 108), radius: 25, color: .white)
    rounded(NSRect(x: 465, y: 675, width: 145, height: 56), radius: 18, color: NSColor.white.withAlphaComponent(0.55))
    rounded(NSRect(x: 633, y: 675, width: 145, height: 56), radius: 18, color: NSColor.white.withAlphaComponent(0.35))
    rounded(NSRect(x: 242, y: 676, width: 48, height: 48), radius: 10, color: NSColor(srgbRed: 0.20, green: 0.43, blue: 0.87, alpha: 1))
    rounded(NSRect(x: 308, y: 691, width: 98, height: 16), radius: 8, color: NSColor(srgbRed: 0.63, green: 0.70, blue: 0.83, alpha: 1))

    let lineColor = NSColor(srgbRed: 0.83, green: 0.87, blue: 0.95, alpha: 1)
    rounded(NSRect(x: 262, y: 526, width: 360, height: 31), radius: 12, color: NSColor(srgbRed: 0.34, green: 0.47, blue: 0.73, alpha: 1))
    for (y, width) in [(452.0, 498.0), (392.0, 498.0), (332.0, 330.0)] {
        rounded(NSRect(x: 262, y: y, width: width, height: 22), radius: 11, color: lineColor)
    }

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OfficeTabs.Icon", code: 2)
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try renderIcon(pixels: size * factor).write(to: outputURL.appendingPathComponent(filename))
    }
}
