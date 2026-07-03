import AppKit
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
}

@MainActor
private final class CanvasHarness {
    let view: CaptureAnnotationNSCanvasView

    init(tool: CaptureTool) {
        view = CaptureAnnotationNSCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setDocument(CaptureDocument(image: Self.fixtureImage(), sourceURL: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0)))
        view.selectedTool = tool
        view.onAnnotationsChanged = { [weak view] annotations in
            view?.annotations = annotations
        }
    }

    func close() {
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
}
