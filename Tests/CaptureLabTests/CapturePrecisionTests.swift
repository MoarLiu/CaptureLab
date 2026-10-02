import AppKit
import XCTest
@testable import CaptureLab

final class CapturePrecisionTests: XCTestCase {
    private let primary = CaptureDisplay(
        id: "primary", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelWidth: 2880, pixelHeight: 1800
    )
    private let left = CaptureDisplay(
        id: "left", frame: CGRect(x: -1280, y: 0, width: 1280, height: 1024),
        pixelWidth: 1280, pixelHeight: 1024
    )

    func testOutputSizeUsesHighestScaleAcrossASelection() {
        let size = PreciseCaptureGeometry.outputSize(
            CGRect(x: -200, y: 100, width: 400, height: 300),
            displays: [left, primary]
        )

        XCTAssertEqual(size, CGSize(width: 800, height: 600))
    }

    @MainActor
    func testSystemDisplayUsesBackingPixelsForOutput() throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw XCTSkip("No display available") }
        let displays = CaptureDisplay.current()
        XCTAssertEqual(displays.count, screens.count)
        for screen in screens {
            let number = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            let uuid = try XCTUnwrap(CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue())
            let id = CFUUIDCreateString(nil, uuid) as String
            let display = try XCTUnwrap(displays.first { $0.id == id })
            let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(number.uint32Value))
            XCTAssertEqual(display.pixelWidth, mode.pixelWidth)
            XCTAssertEqual(display.pixelHeight, mode.pixelHeight)
            let rect = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 400, height: 300)
            XCTAssertEqual(PreciseCaptureGeometry.outputSize(rect, displays: [display]),
                           CGSize(width: 400 * screen.backingScaleFactor, height: 300 * screen.backingScaleFactor))
        }
    }

    @MainActor
    func testRetinaCompositionPreservesPixelsAndRejectsMismatchedFrame() throws {
        let display = CaptureDisplay(id: "retina", frame: CGRect(x: 0, y: 0, width: 40, height: 30),
                                     pixelWidth: 80, pixelHeight: 60)
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(PreciseScreenCapture.compose(rect: display.frame, displays: [display], frames: [display.id: frame]))
        XCTAssertEqual(output.width, 80)
        XCTAssertEqual(output.height, 60)
        XCTAssertNil(PreciseScreenCapture.compose(rect: display.frame, displays: [display],
                                                frames: [display.id: try XCTUnwrap(CGImage.makeTestImage())]))
    }

    @MainActor
    func testLockedRatioSurvivesWidthHeightEditsAndCanBeRelocked() {
        let state = CaptureRegionSelection()
        state.displays = [primary]
        state.setRect(CGRect(x: 10, y: 10, width: 400, height: 200))
        state.locksRatio = true
        state.width = "600"
        state.applySize()
        XCTAssertEqual(state.rect.size, CGSize(width: 600, height: 300))
        state.height = "250"
        state.applySize()
        XCTAssertEqual(state.rect.size, CGSize(width: 500, height: 250))
        state.nudge(key: 124, shift: false, resize: true)
        XCTAssertEqual(state.rect.size, CGSize(width: 501, height: 250.5))
        XCTAssertEqual(state.aspect, 2)
        state.locksRatio = false
        state.width = "400"
        state.height = "400"
        state.applySize()
        state.locksRatio = true
        state.height = "200"
        state.applySize()
        XCTAssertEqual(state.rect.size, CGSize(width: 200, height: 200))
    }

    func testRatioIsPreservedAtEveryDesktopEdge() {
        let bounds = CGRect(x: -1000, y: -500, width: 2000, height: 1000)
        for ratio: CGFloat in [1, 4.0 / 3, 16.0 / 9, 9.0 / 16] {
            for x: CGFloat in [-1, 1] {
                for y: CGFloat in [-1, 1] {
                    let result = PreciseCaptureGeometry.constrainedRect(
                        from: CGPoint(x: x * 900, y: y * 400),
                        to: CGPoint(x: x * 1200, y: y * 800), ratio: ratio, bounds: bounds)
                    XCTAssertTrue(bounds.contains(result))
                    XCTAssertEqual(result.width / result.height, ratio, accuracy: 0.000001)
                }
            }
        }
        let square = PreciseCaptureGeometry.constrainedRect(
            from: CGPoint(x: 900, y: 0), to: CGPoint(x: 1200, y: 300), ratio: 1, bounds: bounds)
        XCTAssertEqual(square.size, CGSize(width: 100, height: 100))
    }

    func testOutputSizeRejectsOutsideDesktopAndHugeSelections() {
        XCTAssertNil(PreciseCaptureGeometry.outputSize(
            CGRect(x: 1400, y: 0, width: 100, height: 100), displays: [primary]
        ))
        XCTAssertNil(PreciseCaptureGeometry.outputSize(
            CGRect(x: 0, y: 0, width: 10_000, height: 10_000), displays: [primary]
        ))
    }

    func testSavedRegionPreservesNegativeDisplayCoordinatesAndInvalidatesChangedDisplays() {
        let rect = CGRect(x: -900, y: 120, width: 500, height: 300)
        let saved = SavedCaptureRegion(rect: rect, displays: [left, primary])

        XCTAssertEqual(saved?.resolve(in: [left, primary]), rect)
        XCTAssertNil(saved?.resolve(in: [primary]))
        XCTAssertNil(saved?.resolve(in: [left, primary].map {
            CaptureDisplay(id: $0.id, frame: $0.frame.offsetBy(dx: 10, dy: 0), pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        }))
    }

    @MainActor
    func testRegionStorePersistsOnlyCompletedSelection() {
        let suite = "CapturePrecisionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptureRegionStore(defaults: defaults)
        let saved = try! XCTUnwrap(SavedCaptureRegion(rect: CGRect(x: 20, y: 20, width: 300, height: 200), displays: [primary]))

        store.save(saved)

        XCTAssertEqual(CaptureRegionStore(defaults: defaults).lastRegion, saved)
    }

    @MainActor
    func testDirectTextRecognitionCopiesSuccessAndPreservesClipboardForEmptyResult() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CapturePrecisionTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let image = try XCTUnwrap(CGImage.makeTestImage())
        let controller = DirectRecognitionController(
            pasteboard: pasteboard,
            text: { _ in OCRResult(text: "recognized", lineCount: 1, createdAt: Date()) }
        )

        controller.start(image: image, kind: .text)
        await waitUntil { !controller.isRunning }
        XCTAssertEqual(pasteboard.string(forType: .string), "recognized")

        let empty = DirectRecognitionController(
            pasteboard: pasteboard,
            text: { _ in OCRResult(text: "", lineCount: 0, createdAt: Date()) }
        )
        empty.start(image: image, kind: .text)
        await waitUntil { !empty.isRunning }
        XCTAssertEqual(pasteboard.string(forType: .string), "recognized")
    }

    @MainActor
    func testDirectRecognitionIgnoresLateReplacedTask() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CapturePrecisionTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let image = try XCTUnwrap(CGImage.makeTestImage())
        var pending: [CheckedContinuation<OCRResult, Never>] = []
        var completed = 0
        let controller = DirectRecognitionController(
            pasteboard: pasteboard,
            text: { _ in
                let result = await withCheckedContinuation { pending.append($0) }
                completed += 1
                return result
            }
        )

        controller.start(image: image, kind: .text)
        await waitUntil { pending.count == 1 }
        XCTAssertEqual(pending.count, 1)
        controller.start(image: image, kind: .text)
        await waitUntil { pending.count == 2 }
        guard pending.count == 2 else {
            pending.forEach { $0.resume(returning: OCRResult(text: "", lineCount: 0, createdAt: Date())) }
            return XCTFail("Both recognition operations must start")
        }
        pending[1].resume(returning: OCRResult(text: "new", lineCount: 1, createdAt: Date()))
        await waitUntil { !controller.isRunning }
        XCTAssertEqual(pasteboard.string(forType: .string), "new")
        pending[0].resume(returning: OCRResult(text: "old", lineCount: 1, createdAt: Date()))
        await waitUntil { completed == 2 }
        await Task.yield()
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "new")
        XCTAssertEqual(controller.results, ["new"])
    }
}

private extension CGImage {
    static func makeTestImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 1, condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && !condition() {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
