// Deterministic instructional GIFs, drawn from native macOS UI primitives.
// No screen capture, TCC requests, or external assets. Run from the repo root:
// xcrun swift scripts/generate-permission-guides.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: "Sources/RimeBuffer/Resources/Permissions", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let iconURL = URL(fileURLWithPath: "Logo/AppIcon.iconset/icon_128x128@2x.png")
let icon = NSImage(contentsOf: iconURL)!
let iconOutput = output.appendingPathComponent("application.png")
try Data(contentsOf: iconURL).write(to: iconOutput)
let size = NSSize(width: 720, height: 232)
let fps = 12
let frames = 60

func smooth(_ value: Double) -> CGFloat {
    let x = CGFloat(min(1, max(0, value)))
    return x * x * (3 - 2 * x)
}

struct Painter {
    let dark: Bool
    var background: NSColor { dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.965, alpha: 1) }
    var surface: NSColor { dark ? NSColor(white: 0.20, alpha: 1) : .white }
    var ink: NSColor { dark ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.15, alpha: 1) }
    var muted: NSColor { dark ? NSColor(white: 0.60, alpha: 1) : NSColor(white: 0.48, alpha: 1) }
    var border: NSColor { dark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.87, alpha: 1) }
    let blue = NSColor(srgbRed: 0.04, green: 0.48, blue: 0.98, alpha: 1)

    func box(_ rect: NSRect, radius: CGFloat = 12, fill: NSColor, stroke: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }
    func text(_ value: String, x: CGFloat, y: CGFloat, font: CGFloat = 18,
              weight: NSFont.Weight = .regular, color: NSColor? = nil) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: font, weight: weight), .foregroundColor: color ?? ink
        ])
    }
    func appIcon(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, alpha: CGFloat = 1) {
        icon.draw(in: NSRect(x: x, y: y, width: width, height: width),
                  from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }
    func cursor(_ x: CGFloat, _ y: CGFloat, pulse: CGFloat = 0) {
        if pulse > 0 {
            box(NSRect(x: x - 17 * pulse, y: y - 17 * pulse, width: 34 * pulse, height: 34 * pulse),
                radius: 30, fill: blue.withAlphaComponent(0.17 * (1 - pulse * 0.5)))
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y))
        for p in [NSPoint(x: x + 2, y: y + 25), NSPoint(x: x + 8, y: y + 19),
                  NSPoint(x: x + 13, y: y + 30), NSPoint(x: x + 18, y: y + 27),
                  NSPoint(x: x + 13, y: y + 17), NSPoint(x: x + 23, y: y + 17)] { path.line(to: p) }
        path.close(); NSColor.black.setFill(); path.fill()
        NSColor.white.setStroke(); path.lineWidth = 1.8; path.stroke()
    }
    func toggle(x: CGFloat, y: CGFloat, on: CGFloat) {
        let off = dark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.79, alpha: 1)
        let color = off.blended(withFraction: on, of: blue) ?? blue
        box(NSRect(x: x, y: y, width: 48, height: 28), radius: 14, fill: color)
        box(NSRect(x: x + 2 + 20 * on, y: y + 2, width: 24, height: 24), radius: 12, fill: .white)
    }
    func settings(_ rect: NSRect) {
        box(rect, fill: surface, stroke: border)
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            box(NSRect(x: rect.minX + 14 + CGFloat(i) * 17, y: rect.minY + 15, width: 9, height: 9), radius: 5, fill: c)
        }
        text("系统设置", x: rect.minX + 76, y: rect.minY + 9, font: 15, weight: .medium)
        text("隐私与安全性", x: rect.minX + 18, y: rect.minY + 45, font: 16, color: muted)
    }
    func appRow(x: CGFloat, y: CGFloat, width: CGFloat, on: CGFloat, old: Bool = false, alpha: CGFloat = 1) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        box(NSRect(x: x, y: y, width: width, height: 58), fill: background, stroke: border)
        appIcon(x + 10, y + 9, 40, alpha: old ? 0.45 : 1)
        text(old ? "旧授权条目（示意）" : "XSIME", x: x + 60, y: y + 17, font: 17, weight: .medium)
        toggle(x: x + width - 62, y: y + 15, on: on)
        NSGraphicsContext.restoreGraphicsState()
    }
    func draw(kind: String, progress t: Double) {
        box(NSRect(origin: .zero, size: size), radius: 18, fill: background)
        if kind == "drag" {
            box(NSRect(x: 18, y: 26, width: 215, height: 180), fill: surface, stroke: border)
            text("权限引导", x: 38, y: 42, font: 17, weight: .semibold)
            let source = NSRect(x: 38, y: 88, width: 76, height: 76)
            box(source, fill: blue.withAlphaComponent(0.06))
            let outline = NSBezierPath(roundedRect: source, xRadius: 10, yRadius: 10)
            outline.setLineDash([5, 4], count: 2, phase: 0)
            outline.lineWidth = 2; blue.setStroke(); outline.stroke()
            appIcon(48, 98, 56)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 140, y: 126)); arrow.line(to: NSPoint(x: 121, y: 126))
            arrow.move(to: NSPoint(x: 127, y: 120)); arrow.line(to: NSPoint(x: 121, y: 126)); arrow.line(to: NSPoint(x: 127, y: 132))
            arrow.lineWidth = 2; blue.setStroke(); arrow.stroke()
            text("拖动这个", x: 147, y: 115, font: 16, weight: .semibold)
            settings(NSRect(x: 302, y: 26, width: 400, height: 180))
            let p = smooth((t - 0.18) / 0.42)
            let arrived = t > 0.65
            let target = NSRect(x: 320, y: 108, width: 364, height: 66)
            if arrived {
                appRow(x: 320, y: 108, width: 364, on: 0)
            } else {
                box(target, fill: blue.withAlphaComponent(0.04), stroke: blue.withAlphaComponent(0.55))
                text("拖入应用", x: 459, y: 128, font: 17, color: muted)
            }
            let x: CGFloat = 76 + 309 * p
            let y: CGFloat = 126 - 26 * sin(p * .pi)
            if t > 0.18 && !arrived { appIcon(x - 20, y - 20, 48, alpha: 0.9) }
            cursor(x, arrived ? 145 : y)
        } else if kind == "repair" {
            settings(NSRect(x: 18, y: 15, width: 684, height: 202))
            let removal = smooth((t - 0.27) / 0.14)
            if t < 0.46 {
                appRow(x: 36, y: 88, width: 648, on: 1, old: true, alpha: 1 - removal)
                if t > 0.10 {
                    box(NSRect(x: 36, y: 88, width: 648, height: 58),
                        fill: blue.withAlphaComponent(0.10 * (1 - removal)),
                        stroke: blue.withAlphaComponent(0.8 * (1 - removal)))
                }
            } else if t > 0.76 {
                appRow(x: 36, y: 88, width: 648, on: smooth((t - 0.82) / 0.07))
            } else {
                box(NSRect(x: 36, y: 88, width: 648, height: 58), fill: background, stroke: border)
            }
            box(NSRect(x: 38, y: 166, width: 31, height: 26), radius: 6, fill: background, stroke: border)
            box(NSRect(x: 73, y: 166, width: 31, height: 26), radius: 6, fill: background, stroke: border)
            text("+", x: 48, y: 167, font: 20)
            text("−", x: 82, y: 167, font: 20)
            if t < 0.44 {
                let p = smooth((t - 0.12) / 0.12)
                cursor(390 - 303 * p, 116 + 62 * p, pulse: t > 0.24 && t < 0.32 ? 0.8 : 0)
            } else {
                let p = smooth((t - 0.48) / 0.28)
                if t < 0.77 { appIcon(150 + 190 * p, 166 - 60 * p, 42) }
                cursor(172 + 190 * p, 184 - 59 * p)
            }
        } else {
            settings(NSRect(x: 18, y: 26, width: 684, height: 180))
            let movement = smooth((t - 0.12) / 0.30)
            let switched = smooth((t - 0.48) / 0.10)
            let on = kind == "disable" ? 1 - switched : switched
            appRow(x: 36, y: 108, width: 648, on: on)
            cursor(355 + 286 * movement, 177 - 42 * movement, pulse: t > 0.45 && t < 0.56 ? 0.8 : 0)
        }
    }
}

for dark in [false, true] {
    for kind in ["drag", "enable", "disable", "repair"] {
        let url = output.appendingPathComponent("\(kind)-\(dark ? "dark" : "light").gif")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else { fatalError("GIF destination") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            try autoreleasepool {
                let image = NSImage(size: size, flipped: true) { _ in
                    Painter(dark: dark).draw(kind: kind, progress: Double(frame) / Double(frames - 1))
                    return true
                }
                guard let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data), let cgImage = bitmap.cgImage else { throw NSError(domain: "permission-gif", code: 1) }
                CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { fatalError("GIF finalization") }
        print(url.path)
    }
}
