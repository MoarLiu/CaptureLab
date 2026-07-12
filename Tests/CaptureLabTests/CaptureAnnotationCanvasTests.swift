import AppKit
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureAnnotationCanvasTests: XCTestCase {
    func testArrowCanBeCreatedAndEndpointDragged() {
        let harness = CanvasHarness(tool: .arrow)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .arrow)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[0].x, 0.125, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.438, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.563, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].y, 0.542, accuracy: 0.01)
    }

    func testLineCanBeCreatedAndEndpointDragged() {
        let harness = CanvasHarness(tool: .line)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .line)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[0].x, 0.125, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.438, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.563, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].y, 0.542, accuracy: 0.01)
    }

    func testCounterCanBeCreatedFromClicksAndAutoIncrements() {
        let harness = CanvasHarness(tool: .counter)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))
        harness.click(at: CGPoint(x: 320, y: 220))

        XCTAssertEqual(harness.view.annotations.count, 2)
        XCTAssertEqual(harness.view.annotations[0].kind, .counter)
        XCTAssertEqual(harness.view.annotations[0].text, "1")
        XCTAssertEqual(harness.view.annotations[1].kind, .counter)
        XCTAssertEqual(harness.view.annotations[1].text, "2")
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.05, accuracy: 0.01)
    }

    func testMosaicCanBeCreatedAndResizedWithHandleDrag() {
        let harness = CanvasHarness(tool: .mosaic)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .mosaic)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.313, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.438, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.height, 0.417, accuracy: 0.01)
    }

    func testTextHighlightCanBeCreatedAndResizedWithHandleDrag() {
        let harness = CanvasHarness(tool: .highlight)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .highlight)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.313, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.438, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.height, 0.417, accuracy: 0.01)
    }

    func testTextCanBeCreatedAndMoved() {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 200, y: 160), to: CGPoint(x: 360, y: 240))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .text)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.minX, 0.188, accuracy: 0.01)
        XCTAssertTrue(harness.view.subviews.contains { $0 is NSTextField })

        harness.view.selectedTool = .select

        harness.drag(from: CGPoint(x: 280, y: 200), to: CGPoint(x: 340, y: 230))

        XCTAssertEqual(harness.view.annotations[0].normalizedRect.minX, 0.281, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.minY, 0.271, accuracy: 0.01)
    }

    func testTextCanBeCreatedFromSingleClick() {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .text)
        XCTAssertEqual(harness.view.annotations[0].text, L10n.defaultAnnotationText)
        XCTAssertTrue(harness.view.subviews.contains { $0 is NSTextField })
    }

    func testSelectedAnnotationCanBeDeletedWithKeyboard() {
        let harness = CanvasHarness(tool: .rectangle)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))
        XCTAssertEqual(harness.view.annotations.count, 1)

        harness.keyDown(characters: "\u{7F}", keyCode: 51)

        XCTAssertTrue(harness.view.annotations.isEmpty)
    }

    func testEditingSessionSynchronouslyCommitsPendingTextBeforeFocusEnds() throws {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))
        let field = try XCTUnwrap(harness.view.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Pending export text"
        XCTAssertNotEqual(harness.view.annotations[0].text, "Pending export text")

        CaptureEditingSession.commitPendingTextEdits()

        XCTAssertEqual(harness.view.annotations[0].text, "Pending export text")
        XCTAssertFalse(harness.view.subviews.contains { $0 is NSTextField })
    }

    func testDismantleCommitsPendingTextBeforeZoomRebuild() throws {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))
        let field = try XCTUnwrap(harness.view.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Text preserved across zoom"
        XCTAssertNotEqual(harness.boundAnnotations[0].text, "Text preserved across zoom")

        harness.dismantle()

        XCTAssertEqual(harness.boundAnnotations[0].text, "Text preserved across zoom")
        XCTAssertFalse(harness.view.subviews.contains { $0 is NSTextField })

        // Fixed zoom wraps the representable in a ScrollView, so SwiftUI builds
        // a replacement AppKit canvas from the binding committed at teardown.
        let replacement = CaptureAnnotationNSCanvasView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        replacement.annotations = harness.boundAnnotations
        XCTAssertEqual(replacement.annotations[0].text, "Text preserved across zoom")
    }

    func testStaticMosaicReusesCachedImageAndReplacesResizedEntry() throws {
        let harness = CanvasHarness(tool: .mosaic)
        defer { harness.close() }
        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        let annotation = try XCTUnwrap(harness.view.annotations.first)
        let first = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))
        let second = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))

        XCTAssertTrue(first === second)
        XCTAssertEqual(harness.view.mosaicCacheEntryCount, 1)

        let resized = annotation.withNormalizedRect(
            CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.5)
        )
        harness.view.annotations = [resized]
        let replacement = try XCTUnwrap(harness.view.cachedPixelatedImage(for: resized))

        XCTAssertFalse(first === replacement)
        XCTAssertEqual(harness.view.mosaicCacheEntryCount, 1)
    }

    func testMosaicCacheGrowthIsBounded() throws {
        let harness = CanvasHarness(tool: .mosaic)
        defer { harness.close() }
        let annotations = (0..<40).map { index in
            CaptureAnnotation(
                kind: .mosaic,
                normalizedRect: CGRect(
                    x: CGFloat(index % 8) * 0.1,
                    y: CGFloat(index / 8) * 0.1,
                    width: 0.08,
                    height: 0.08
                )
            )
        }
        harness.view.annotations = annotations

        for annotation in annotations {
            _ = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))
        }

        XCTAssertLessThanOrEqual(harness.view.mosaicCacheEntryCount, 32)
        XCTAssertLessThanOrEqual(harness.view.mosaicCacheCostInPixels, 16_000_000)
    }

    func testSixKFullFrameMosaicPreviewRemainsCached() throws {
        let source = try CanvasHarness.sixKFixtureImage()
        let harness = CanvasHarness(tool: .mosaic, image: source)
        defer { harness.close() }
        let annotation = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        harness.view.annotations = [annotation]

        XCTAssertGreaterThan(6_144 * 3_456, 16_000_000)
        let first = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))
        let second = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))

        XCTAssertTrue(first === second)
        XCTAssertEqual(harness.view.mosaicCacheEntryCount, 1)
        XCTAssertLessThanOrEqual(harness.view.mosaicCacheCostInPixels, 4_000_000)
    }

    func testMultipleLargeMosaicRegionsSurviveRepeatedDrawOrder() throws {
        let source = try CanvasHarness.sixKFixtureImage()
        let harness = CanvasHarness(tool: .mosaic, image: source)
        defer { harness.close() }
        let annotations = (0..<3).map { index in
            CaptureAnnotation(
                kind: .mosaic,
                normalizedRect: CGRect(
                    x: CGFloat(index) / 3,
                    y: 0,
                    width: 1 / 3,
                    height: 1
                )
            )
        }
        harness.view.annotations = annotations

        // At source resolution these three regions exceed the old 16M-pixel
        // budget in aggregate and a sequential LRU scan evicted every entry.
        XCTAssertGreaterThan(6_144 * 3_456, 16_000_000)
        let firstPass = try annotations.map {
            try XCTUnwrap(harness.view.cachedPixelatedImage(for: $0))
        }
        let secondPass = try annotations.map {
            try XCTUnwrap(harness.view.cachedPixelatedImage(for: $0))
        }

        XCTAssertEqual(harness.view.mosaicCacheEntryCount, annotations.count)
        XCTAssertLessThanOrEqual(harness.view.mosaicCacheCostInPixels, 16_000_000)
        for index in annotations.indices {
            XCTAssertTrue(firstPass[index] === secondPass[index])
        }
    }
}

@MainActor
private final class CanvasHarness {
    let view: CaptureAnnotationNSCanvasView
    private let annotationBox = CanvasAnnotationBox()

    init(tool: CaptureTool, image: NSImage? = nil) {
        view = CaptureAnnotationNSCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setDocument(CaptureDocument(
            image: image ?? Self.fixtureImage(),
            sourceURL: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        ))
        view.setEditingSession(.shared)
        view.selectedTool = tool
        view.onAnnotationsChanged = { [weak view, annotationBox] annotations in
            annotationBox.annotations = annotations
            view?.annotations = annotations
        }
    }

    var boundAnnotations: [CaptureAnnotation] {
        annotationBox.annotations
    }

    func close() {
        view.prepareForDismantle()
    }

    func dismantle() {
        let binding = Binding<[CaptureAnnotation]>(
            get: { self.annotationBox.annotations },
            set: { self.annotationBox.annotations = $0 }
        )
        CaptureAnnotationCanvasView.dismantleNSView(
            view,
            coordinator: CaptureAnnotationCanvasView.Coordinator(annotations: binding)
        )
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        view.mouseDown(with: event(type: .leftMouseDown, location: start))
        view.mouseDragged(with: event(type: .leftMouseDragged, location: end))
        view.mouseUp(with: event(type: .leftMouseUp, location: end))
    }

    func click(at point: CGPoint) {
        view.mouseDown(with: event(type: .leftMouseDown, location: point))
        view.mouseUp(with: event(type: .leftMouseUp, location: point))
    }

    func keyDown(characters: String, keyCode: UInt16) {
        view.keyDown(with: NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!)
    }

    private func event(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private static func fixtureImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        NSColor.black.setFill()
        NSRect(x: 80, y: 70, width: 240, height: 160).fill()
        image.unlockFocus()
        return image
    }

    static func sixKFixtureImage() throws -> NSImage {
        let width = 6_144
        let height = 3_456
        let bytesPerRow = (width + 7) / 8
        let provider = try XCTUnwrap(CGDataProvider(
            data: Data(repeating: 0b1010_1010, count: bytesPerRow * height) as CFData
        ))
        let source = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return NSImage(cgImage: source, size: CGSize(width: width, height: height))
    }
}

@MainActor
private final class CanvasAnnotationBox {
    var annotations: [CaptureAnnotation] = []
}
