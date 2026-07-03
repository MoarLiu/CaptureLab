#!/usr/bin/env swift
import AppKit
import Foundation

let rootPath = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let rootURL = URL(fileURLWithPath: rootPath)
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("CaptureLab.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("CaptureLab.icns")
let fileManager = FileManager.default

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

struct IconSlot {
    let name: String
    let pixels: Int
}

let slots = [
    IconSlot(name: "icon_16x16.png", pixels: 16),
    IconSlot(name: "icon_16x16@2x.png", pixels: 32),
    IconSlot(name: "icon_32x32.png", pixels: 32),
    IconSlot(name: "icon_32x32@2x.png", pixels: 64),
    IconSlot(name: "icon_128x128.png", pixels: 128),
    IconSlot(name: "icon_128x128@2x.png", pixels: 256),
    IconSlot(name: "icon_256x256.png", pixels: 256),
    IconSlot(name: "icon_256x256@2x.png", pixels: 512),
    IconSlot(name: "icon_512x512.png", pixels: 512),
    IconSlot(name: "icon_512x512@2x.png", pixels: 1024)
]

for slot in slots {
    let image = drawCaptureLabIcon(pixels: slot.pixels)
    let data = try pngData(from: image, pixels: slot.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(slot.name), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "CaptureLabIcon", code: Int(iconutil.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "iconutil failed to create \(icnsURL.path)"
    ])
}

func drawCaptureLabIcon(pixels: Int) -> NSImage {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let inset = size * 0.055
    let backgroundRect = rect.insetBy(dx: inset, dy: inset)
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )

    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    backgroundPath.addClip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(calibratedRed: 0.02, green: 0.22, blue: 0.92, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.76, blue: 0.96, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.63, green: 0.17, blue: 0.95, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.48, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: backgroundRect.minX, y: backgroundRect.maxY),
        end: CGPoint(x: backgroundRect.maxX, y: backgroundRect.minY),
        options: []
    )

    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.06, y: size * 0.54, width: size * 0.72, height: size * 0.5)).fill()
    context.restoreGState()

    NSColor.white.withAlphaComponent(0.24).setStroke()
    backgroundPath.lineWidth = max(1, size * 0.012)
    backgroundPath.stroke()

    drawCaptureFrame(in: rect, size: size)
    drawLabFlask(in: rect, size: size)

    return image
}

func drawCaptureFrame(in rect: NSRect, size: CGFloat) {
    let frame = rect.insetBy(dx: size * 0.2, dy: size * 0.2)
    let length = size * 0.16
    let lineWidth = max(1.8, size * 0.05)
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    path.move(to: CGPoint(x: frame.minX, y: frame.maxY - length))
    path.line(to: CGPoint(x: frame.minX, y: frame.maxY))
    path.line(to: CGPoint(x: frame.minX + length, y: frame.maxY))

    path.move(to: CGPoint(x: frame.maxX - length, y: frame.maxY))
    path.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
    path.line(to: CGPoint(x: frame.maxX, y: frame.maxY - length))

    path.move(to: CGPoint(x: frame.maxX, y: frame.minY + length))
    path.line(to: CGPoint(x: frame.maxX, y: frame.minY))
    path.line(to: CGPoint(x: frame.maxX - length, y: frame.minY))

    path.move(to: CGPoint(x: frame.minX + length, y: frame.minY))
    path.line(to: CGPoint(x: frame.minX, y: frame.minY))
    path.line(to: CGPoint(x: frame.minX, y: frame.minY + length))

    NSColor.white.withAlphaComponent(0.92).setStroke()
    path.stroke()
}

func drawLabFlask(in rect: NSRect, size: CGFloat) {
    let flask = NSBezierPath()
    flask.move(to: CGPoint(x: size * 0.45, y: size * 0.67))
    flask.line(to: CGPoint(x: size * 0.45, y: size * 0.77))
    flask.line(to: CGPoint(x: size * 0.55, y: size * 0.77))
    flask.line(to: CGPoint(x: size * 0.55, y: size * 0.67))
    flask.curve(
        to: CGPoint(x: size * 0.72, y: size * 0.32),
        controlPoint1: CGPoint(x: size * 0.61, y: size * 0.59),
        controlPoint2: CGPoint(x: size * 0.69, y: size * 0.43)
    )
    flask.curve(
        to: CGPoint(x: size * 0.28, y: size * 0.32),
        controlPoint1: CGPoint(x: size * 0.62, y: size * 0.22),
        controlPoint2: CGPoint(x: size * 0.38, y: size * 0.22)
    )
    flask.curve(
        to: CGPoint(x: size * 0.45, y: size * 0.67),
        controlPoint1: CGPoint(x: size * 0.31, y: size * 0.43),
        controlPoint2: CGPoint(x: size * 0.39, y: size * 0.59)
    )
    flask.close()

    NSColor.white.withAlphaComponent(0.94).setFill()
    flask.fill()

    NSColor.black.withAlphaComponent(0.16).setStroke()
    flask.lineWidth = max(1.2, size * 0.014)
    flask.stroke()

    let liquid = NSBezierPath()
    liquid.move(to: CGPoint(x: size * 0.34, y: size * 0.37))
    liquid.curve(
        to: CGPoint(x: size * 0.66, y: size * 0.37),
        controlPoint1: CGPoint(x: size * 0.43, y: size * 0.43),
        controlPoint2: CGPoint(x: size * 0.57, y: size * 0.31)
    )
    liquid.line(to: CGPoint(x: size * 0.62, y: size * 0.47))
    liquid.curve(
        to: CGPoint(x: size * 0.38, y: size * 0.47),
        controlPoint1: CGPoint(x: size * 0.55, y: size * 0.42),
        controlPoint2: CGPoint(x: size * 0.45, y: size * 0.51)
    )
    liquid.close()
    NSColor(calibratedRed: 0.03, green: 0.52, blue: 1, alpha: 0.9).setFill()
    liquid.fill()

    NSColor.white.withAlphaComponent(0.58).setStroke()
    let shine = NSBezierPath()
    shine.lineWidth = max(1.2, size * 0.02)
    shine.lineCapStyle = .round
    shine.move(to: CGPoint(x: size * 0.43, y: size * 0.59))
    shine.curve(
        to: CGPoint(x: size * 0.35, y: size * 0.39),
        controlPoint1: CGPoint(x: size * 0.39, y: size * 0.53),
        controlPoint2: CGPoint(x: size * 0.36, y: size * 0.45)
    )
    shine.stroke()
}

func pngData(from image: NSImage, pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CaptureLabIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to encode icon PNG"
        ])
    }
    return data
}
