import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureCounterResizeTests: XCTestCase {
    func testResizingCounterKeepsEveryDigitInsideCircleInExport() throws {
        let canvas = try makeCanvas()
        canvas.annotations = [counter("12", side: 160)]
        canvas.synchronizeSelection(canvas.annotations[0].id)
        drag(canvas, from: CGPoint(x: 400, y: 340), to: CGPoint(x: 280, y: 220))
        let resized = try XCTUnwrap(canvas.annotations.first)
        XCTAssertEqual(resized.normalizedRect.width * 640, 40, accuracy: 0.001)
        XCTAssertEqual(resized.text, "12")

        let first = try export(resized)
        var differentLastDigit = resized
        differentLastDigit.text = "13"
        XCTAssertNotEqual(try pixels(first), try pixels(export(differentLastDigit)),
                          "The last digit must remain visible after resizing.")
        try assertNumberInsideCircle(first, rect: resized.rect(in: CGRect(x: 0, y: 0, width: 640, height: 480)))
    }

    func testMultiDigitCountersFitNarrowBoundsAtEveryPreviewZoom() throws {
        for zoom in [CaptureZoomLevel.half, .actual, .double] {
            let scale = try XCTUnwrap(zoom.scale)
            let canvas = try makeCanvas(scale: scale)
            canvas.zoomLevel = zoom
            var annotation = counter("1234", side: 40)
            annotation.normalizedRect.size.height *= 2
            canvas.annotations = [annotation]
            let first = try preview(canvas)
            annotation.text = "1235"
            canvas.annotations = [annotation]
            XCTAssertNotEqual(try pixels(first), try pixels(preview(canvas)),
                              "The last digit must render at \(zoom.title).")
            let imageRect = CGRect(x: 80, y: 60, width: 640 * scale, height: 480 * scale)
            let bounds = annotation.rect(in: imageRect)
            let circle = CGRect(x: bounds.minX, y: bounds.midY - bounds.width / 2,
                                width: bounds.width, height: bounds.width)
            // Cache bitmaps use the current display's backing scale.
            let backingScale = CGFloat(first.pixelsWide) / canvas.bounds.width
            try assertNumberInsideCircle(first, rect: CGRect(
                x: circle.minX * backingScale, y: circle.minY * backingScale,
                width: circle.width * backingScale, height: circle.height * backingScale
            ))
        }
    }

    func testCounterFittingScalesConsistentlyAndPreservesRequestedFontWhenItFits() {
        let appearance = CaptureAnnotationAppearance(fontSize: 96)
        let exportStyle = CaptureAnnotationStyle(sourcePixelSize: CGSize(width: 640, height: 480),
            renderedImageSize: CGSize(width: 640, height: 480), appearance: appearance)
        XCTAssertEqual(exportStyle.counterFontSize(for: 300, text: "12"), 96)
        for scale: CGFloat in [0.5, 2] {
            let previewStyle = CaptureAnnotationStyle(sourcePixelSize: CGSize(width: 640, height: 480),
                renderedImageSize: CGSize(width: 640 * scale, height: 480 * scale), appearance: appearance)
            XCTAssertEqual(previewStyle.counterFontSize(for: 40 * scale, text: "1234"),
                           exportStyle.counterFontSize(for: 40, text: "1234") * scale, accuracy: 0.0001)
        }
    }

    private func counter(_ text: String, side: CGFloat) -> CaptureAnnotation {
        CaptureAnnotation(kind: .counter,
            normalizedRect: CGRect(x: 0.25, y: 0.25, width: side / 640, height: side / 480), text: text,
            appearance: CaptureAnnotationAppearance(color: CaptureAnnotationColor(.red), fontSize: 96))
    }

    private func makeCanvas(scale: CGFloat = 1) throws -> CaptureAnnotationNSCanvasView {
        _ = NSApplication.shared
        let canvas = CaptureAnnotationNSCanvasView(frame: CGRect(x: 0, y: 0,
            width: 640 * scale + 160, height: 480 * scale + 120))
        canvas.setDocument(CaptureDocument(image: try sourceImage(), sourceURL: nil, createdAt: Date()))
        return canvas
    }

    private func drag(_ canvas: CaptureAnnotationNSCanvasView, from start: CGPoint, to end: CGPoint) {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
    }

    private func export(_ annotation: CaptureAnnotation) throws -> NSBitmapImageRep {
        let rendered = try XCTUnwrap(sourceImage().renderedWithCaptureLabAnnotations([annotation]))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(rendered.captureLabCGImage()))
    }

    private func preview(_ canvas: CaptureAnnotationNSCanvasView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return bitmap
    }

    private func pixels(_ bitmap: NSBitmapImageRep) throws -> Data {
        Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func assertNumberInsideCircle(_ bitmap: NSBitmapImageRep, rect: CGRect,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        var inside = 0
        var outside = 0
        // Include the old 96-point glyph's spill region, but stay within the
        // synthetic white image rather than the native canvas background.
        let sample = rect.insetBy(dx: -rect.width, dy: -rect.height)
            .intersection(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        for y in Int(sample.minY)..<Int(sample.maxY) {
            for x in Int(sample.minX)..<Int(sample.maxX) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                guard max(color.redComponent, color.greenComponent, color.blueComponent) < 0.25 else { continue }
                if hypot(CGFloat(x) + 0.5 - rect.midX, CGFloat(y) + 0.5 - rect.midY) <= rect.width / 2 + 1 {
                    inside += 1
                } else {
                    outside += 1
                }
            }
        }
        XCTAssertGreaterThan(inside, 5, "The number must be visible", file: file, line: line)
        XCTAssertEqual(outside, 0, "The number must fit inside the circle", file: file, line: line)
    }

    private func sourceImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 640, height: 480))
    }
}
