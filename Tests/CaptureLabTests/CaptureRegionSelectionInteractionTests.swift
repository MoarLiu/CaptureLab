import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureRegionSelectionInteractionTests: XCTestCase {
    func testMouseReleaseConfirmsFinalSelectionOnceForLiveAndFrozenCapture() throws {
        _ = NSApplication.shared
        for frozen in [false, true] {
            let display = CaptureDisplay(id: "test", frame: CGRect(x: -400, y: 0, width: 400, height: 300),
                                         pixelWidth: 800, pixelHeight: 600)
            let state = CaptureRegionSelection()
            state.displays = [display]
            state.showsMagnifier = false
            let view = RegionSelectionView(state: state, display: display, snapshot: nil, frozen: frozen)
            let window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            var confirmed: [CGRect] = []
            state.finish = { confirmed.append(state.rect) }

            view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 30, y: 40), window: window))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 100, y: 90), window: window))
            XCTAssertTrue(confirmed.isEmpty)
            let release = try mouse(.leftMouseUp, at: CGPoint(x: 160, y: 140), window: window)
            view.mouseUp(with: release)
            view.mouseUp(with: release)

            XCTAssertEqual(confirmed, [CGRect(x: -370, y: 40, width: 130, height: 100)])
            XCTAssertEqual(state.width, "130.0")
            XCTAssertEqual(state.height, "100.0")
            XCTAssertEqual(PreciseCaptureGeometry.outputSize(state.rect, displays: [display]), CGSize(width: 260, height: 200))
        }
    }

    func testClickWithoutARegionDoesNotConfirm() throws {
        _ = NSApplication.shared
        let display = CaptureDisplay(id: "test", frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                     pixelWidth: 800, pixelHeight: 600)
        let state = CaptureRegionSelection()
        state.displays = [display]
        state.showsMagnifier = false
        let view = RegionSelectionView(state: state, display: display, snapshot: nil, frozen: false)
        let window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        state.finish = { XCTFail("An empty selection must not capture") }

        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 30, y: 40), window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 30, y: 40), window: window))

        XCTAssertFalse(state.rect.hasPositiveArea)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
