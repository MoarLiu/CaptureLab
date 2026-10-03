import AppKit
import XCTest
@testable import CaptureLab

final class CaptureAdvancedAnnotationTests: XCTestCase {
    func testLegacyAppearanceDecodesAndAdvancedStyleRoundTrips() throws {
        let legacy = try JSONDecoder().decode(CaptureAnnotationAppearance.self, from: Data("{\"lineWidth\":4,\"fontSize\":24}".utf8))
        XCTAssertNil(legacy.arrowStyle)
        XCTAssertTrue(legacy.isValid)
        var style = legacy
        style.arrowStyle = .doubleEnded; style.shapeFill = .strokeAndFill
        style.fillColor = CaptureAnnotationColor(.blue); style.fontFamily = "Helvetica"
        style.fontWeight = .heavy; style.textAlignment = .left
        style.textBackgroundColor = CaptureAnnotationColor(.white)
        style.textBorderColor = CaptureAnnotationColor(.black)
        style.blurRadius = 25; style.spotlightOpacity = 0.8; style.brushSmoothing = 0.7
        let roundTrip = try JSONDecoder().decode(CaptureAnnotationAppearance.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(style, roundTrip)
        style.blurRadius = .infinity
        XCTAssertFalse(style.isValid)
    }

    func testLegacyLegalMaximumStyleValuesRemainValid() throws {
        let data = Data("{\"lineWidth\":1024,\"fontSize\":4096}".utf8)
        let legacy = try JSONDecoder().decode(CaptureAnnotationAppearance.self, from: data)
        XCTAssertTrue(legacy.isValid)
        var oversized = legacy
        oversized.fontSize = 4097
        XCTAssertFalse(oversized.isValid)
        oversized = legacy
        oversized.lineWidth = 1025
        XCTAssertFalse(oversized.isValid)
    }

    func testCurveControlSurvivesMoveScaleAndSerialization() throws {
        let arrow = CaptureAnnotation.curvedArrow(start: CGPoint(x: 0.1, y: 0.3), end: CGPoint(x: 0.6, y: 0.7), control: CGPoint(x: 0.4, y: 0.1))
        let moved = arrow.translatedBy(dx: 0.1, dy: 0.1)
        XCTAssertEqual(moved.normalizedPoints[2].x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(moved.normalizedPoints[2].y, 0.2, accuracy: 0.00001)
        let scaled = arrow.scaledToNormalizedRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(scaled.normalizedPoints[0].x, 0, accuracy: 0.00001)
        XCTAssertEqual(scaled.normalizedPoints[1].x, 1, accuracy: 0.00001)
        XCTAssertEqual(scaled.normalizedPoints[2].y, 0, accuracy: 0.00001)
        let decoded = try JSONDecoder().decode(CaptureAnnotation.self, from: JSONEncoder().encode(scaled))
        XCTAssertEqual(decoded, scaled)
        let curve = CaptureAnnotationPaths.curvePoints(arrow.normalizedPoints.map(\.cgPoint))
        XCTAssertEqual(curve.first, arrow.normalizedPoints[0].cgPoint)
        XCTAssertEqual(curve.last, arrow.normalizedPoints[1].cgPoint)
        XCTAssertLessThan(curve[16].y, 0.4)
    }

    func testTextAlignmentSnapsOnlyOneLineAndKeepsHorizontalManualBounds() {
        let line = CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.05)
        let proposed = CGRect(x: 0.2, y: 0.21, width: 0.3, height: 0.04)
        let aligned = CaptureHighlightAlignment.alignedRect(proposed, textRegions: [line])
        XCTAssertEqual(aligned.minX, proposed.minX)
        XCTAssertEqual(aligned.width, proposed.width)
        XCTAssertEqual(aligned.midY, line.midY, accuracy: 0.00001)
        let multiline = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2)
        XCTAssertEqual(CaptureHighlightAlignment.alignedRect(multiline, textRegions: [line, line.offsetBy(dx: 0, dy: 0.1)]), multiline)
    }

    func testCurveEndpointControlUsesTheLimitingTangentForArrowheads() throws {
        let source = try image(color: .white)
        let start = CGPoint(x: 0.1, y: 0.2), end = CGPoint(x: 0.8, y: 0.7)
        var straight = CaptureAnnotation.arrow(start: start, end: end)
        straight.appearance.lineWidth = 4
        straight.appearance.arrowStyle = .doubleEnded
        straight.appearance.color = CaptureAnnotationColor(.red)
        let reference = try bitmap(source, [straight])
        for (control, sample) in [(end, CGPoint(x: 73, y: 57)), (start, CGPoint(x: 18, y: 32))] {
            var curved = CaptureAnnotation.curvedArrow(start: start, end: end, control: control)
            curved.appearance = straight.appearance
            let output = try bitmap(source, [curved])
            let expected = try XCTUnwrap(reference.colorAt(x: Int(sample.x), y: Int(sample.y)))
            let actual = try XCTUnwrap(output.colorAt(x: Int(sample.x), y: Int(sample.y)))
            XCTAssertLessThan(expected.greenComponent, 0.1)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
        }
    }

    func testSmoothingUsesCurvesWithoutOvershootingSampleBounds() {
        let points = [CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 15), CGPoint(x: 30, y: 10)]
        let raw = CaptureAnnotationPaths.brush(points, smoothing: 0)
        let smooth = CaptureAnnotationPaths.brush(points, smoothing: 1)
        XCTAssertEqual(raw.element(at: 1), .lineTo)
        XCTAssertNotEqual(smooth.element(at: 1), .lineTo)
        XCTAssertGreaterThanOrEqual(smooth.bounds.minX, 5)
        XCTAssertLessThanOrEqual(smooth.bounds.maxX, 30)
        XCTAssertGreaterThanOrEqual(smooth.bounds.minY, 5)
        XCTAssertLessThanOrEqual(smooth.bounds.maxY, 15)
    }

    func testFilledEllipseAndSpotlightExportCorrectInteriorAndExterior() throws {
        let source = try image(color: .white)
        var ellipse = CaptureAnnotation(kind: .ellipse, normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        ellipse.appearance.color = CaptureAnnotationColor(.red); ellipse.appearance.shapeFill = .fill
        let output = try bitmap(source, [ellipse])
        XCTAssertGreaterThan(try XCTUnwrap(output.colorAt(x: 50, y: 50)).redComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(output.colorAt(x: 50, y: 50)).greenComponent, 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(output.colorAt(x: 21, y: 21)).greenComponent, 0.9)
        let spotlight = CaptureAnnotation(kind: .spotlight, normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let lit = try bitmap(source, [spotlight])
        XCTAssertGreaterThan(try XCTUnwrap(lit.colorAt(x: 50, y: 50)).redComponent, 0.95)
        XCTAssertLessThan(try XCTUnwrap(lit.colorAt(x: 5, y: 5)).redComponent, 0.5)
    }

    func testBlurAndMosaicSamplePreviouslyRenderedRedaction() throws {
        let source = try image(color: .white)
        var cover = CaptureAnnotation(kind: .filledRectangle, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        cover.appearance.color = CaptureAnnotationColor(.black)
        for kind in [CaptureAnnotation.Kind.blur, .mosaic] {
            let effect = CaptureAnnotation(kind: kind, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            let rendered = try bitmap(source, [cover, effect])
            let center = try XCTUnwrap(rendered.colorAt(x: 50, y: 50))
            XCTAssertLessThan(center.redComponent, 0.05, "\(kind) must not uncover the white source")
        }
    }

    func testBlurIntensityChangesOutputAndDoesNotAlterOutsideRegion() throws {
        let source = try image(color: .white)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<100 { for x in 45..<55 {
            let index = y * bitmap.bytesPerRow + x * 4
            bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
        } }
        var blur = CaptureAnnotation(kind: .blur, normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        blur.appearance.blurRadius = 1
        let narrow = try self.bitmap(source, [blur])
        blur.appearance.blurRadius = 25
        let broad = try self.bitmap(source, [blur])
        XCTAssertGreaterThan(try XCTUnwrap(broad.colorAt(x: 50, y: 50)).redComponent,
                             try XCTUnwrap(narrow.colorAt(x: 50, y: 50)).redComponent + 0.2)
        XCTAssertEqual(try XCTUnwrap(broad.colorAt(x: 50, y: 5)).redComponent, 0, accuracy: 0.01)
    }

    private func image(color: NSColor) throws -> NSImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(rep.bitmapData)
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        for y in 0..<100 { for x in 0..<100 {
            let index = y * rep.bytesPerRow + x * 4
            bytes[index] = UInt8(rgb.redComponent * 255)
            bytes[index + 1] = UInt8(rgb.greenComponent * 255)
            bytes[index + 2] = UInt8(rgb.blueComponent * 255)
            bytes[index + 3] = 255
        } }
        let image = NSImage(size: CGSize(width: 100, height: 100)); image.addRepresentation(rep)
        return image
    }
    private func bitmap(_ source: NSImage, _ annotations: [CaptureAnnotation]) throws -> NSBitmapImageRep {
        let rendered = try XCTUnwrap(source.renderedWithCaptureLabAnnotations(annotations))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(rendered.captureLabCGImage()))
    }
}

@MainActor
final class CaptureAdvancedAnnotationCanvasTests: XCTestCase {
    func testEachNewToolCreatesSelectableMovableAnnotation() throws {
        for tool in [CaptureTool.ellipse, .filledRectangle, .curvedArrow, .spotlight, .blur] {
            let view = canvas(tool: tool)
            defer { view.prepareForDismantle() }
            drag(view, from: CGPoint(x: 210, y: 190), to: CGPoint(x: 450, y: 370))
            let original = try XCTUnwrap(view.annotations.first)
            XCTAssertEqual(original.kind, tool.annotationKind)
            view.selectedTool = .select
            view.synchronizeSelection(original.id)
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
            view.keyDown(with: key)
            XCTAssertGreaterThan(try XCTUnwrap(view.annotations.first).normalizedBounds.minX, original.normalizedBounds.minX)
        }
    }

    func testCurveThirdHandleCanBeMovedWithoutChangingEndpoints() throws {
        let view = canvas(tool: .curvedArrow)
        defer { view.prepareForDismantle() }
        drag(view, from: CGPoint(x: 210, y: 220), to: CGPoint(x: 470, y: 350))
        let original = try XCTUnwrap(view.annotations.first)
        let rect = view.outputDisplayRect
        let handle = original.points(in: rect)[2]
        drag(view, from: handle, to: CGPoint(x: handle.x + 25, y: handle.y - 20))
        let adjusted = try XCTUnwrap(view.annotations.first)
        XCTAssertEqual(adjusted.normalizedPoints[0], original.normalizedPoints[0])
        XCTAssertEqual(adjusted.normalizedPoints[1], original.normalizedPoints[1])
        XCTAssertGreaterThan(adjusted.normalizedPoints[2].x, original.normalizedPoints[2].x)
        XCTAssertLessThan(adjusted.normalizedPoints[2].y, original.normalizedPoints[2].y)
    }

    private func canvas(tool: CaptureTool) -> CaptureAnnotationNSCanvasView {
        let image = NSImage(size: CGSize(width: 400, height: 300))
        image.lockFocus(); NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 400, height: 300).fill(); image.unlockFocus()
        let view = CaptureAnnotationNSCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.setDocument(CaptureDocument(image: image, sourceURL: nil, createdAt: Date()))
        view.selectedTool = tool
        return view
    }
    private func drag(_ view: CaptureAnnotationNSCanvasView, from: CGPoint, to: CGPoint) {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, from))
        view.mouseDragged(with: event(.leftMouseDragged, to))
        view.mouseUp(with: event(.leftMouseUp, to))
    }
}
