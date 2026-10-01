import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CounterContrastTests: XCTestCase {
    func testExportedCounterNumbersRemainVisibleOnLightAndDarkFills() throws {
        for color in [NSColor.white, .systemYellow, .black, .systemBlue, .systemRed, .gray] {
            XCTAssertNotEqual(try export(number: "1", color: color), try export(number: "2", color: color),
                              "The number must remain visible with fill \(color).")
        }
    }

    func testCanvasCounterNumbersRemainVisibleOnLightAndDarkFills() throws {
        _ = NSApplication.shared
        for color in [NSColor.white, .systemYellow, .black, .systemBlue] {
            XCTAssertNotEqual(try preview(number: "1", color: color), try preview(number: "2", color: color),
                              "The canvas number must remain visible with fill \(color).")
        }
    }

    private func annotation(number: String, color: NSColor) -> CaptureAnnotation {
        CaptureAnnotation(
            kind: .counter,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            text: number,
            appearance: CaptureAnnotationAppearance(color: CaptureAnnotationColor(color), fontSize: 24)
        )
    }

    private func export(number: String, color: NSColor) throws -> Data {
        let source = try sourceImage()
        let rendered = try XCTUnwrap(source.renderedWithCaptureLabAnnotations([annotation(number: number, color: color)]))
        return try pixels(NSBitmapImageRep(cgImage: XCTUnwrap(rendered.captureLabCGImage())))
    }

    private func preview(number: String, color: NSColor) throws -> Data {
        let canvas = CaptureAnnotationNSCanvasView(frame: CGRect(x: 0, y: 0, width: 256, height: 216))
        canvas.setDocument(CaptureDocument(image: try sourceImage(), sourceURL: nil, createdAt: Date()))
        canvas.zoomLevel = .actual
        canvas.annotations = [annotation(number: number, color: color)]
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return try pixels(bitmap)
    }

    private func pixels(_ bitmap: NSBitmapImageRep) throws -> Data {
        Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func sourceImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 96, height: 96))
    }
}
