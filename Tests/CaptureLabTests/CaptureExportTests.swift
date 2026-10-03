import AppKit
import ImageIO
import XCTest
@testable import CaptureLab

final class CaptureExportTests: XCTestCase {
    func testPNGKeepsAlphaWhileJPEGUsesExplicitMatteAndDimensions() throws {
        let source = try makeSource()
        var settings = CaptureExportSettings()
        settings.width = 24; settings.height = 16
        let png = try settings.encode(source)
        let pngBitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(pngBitmap.pixelsWide, 24); XCTAssertEqual(pngBitmap.pixelsHigh, 16)
        XCTAssertEqual(try XCTUnwrap(pngBitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
        settings.format = .jpeg; settings.quality = 1
        settings.matte = CaptureRGBAColor(red: 0, green: 0, blue: 1, alpha: 0.2)
        let jpeg = try settings.encode(source)
        let jpegBitmap = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(jpegBitmap.pixelsWide, 24); XCTAssertEqual(jpegBitmap.pixelsHigh, 16)
        let corner = try XCTUnwrap(jpegBitmap.colorAt(x: 0, y: 0)).usingColorSpace(.sRGB)!
        XCTAssertEqual(corner.alphaComponent, 1)
        XCTAssertEqual(corner.blueComponent, 1, accuracy: 0.08)
        XCTAssertLessThan(corner.redComponent, 0.08)
        XCTAssertEqual(jpeg.prefix(2), Data([0xff, 0xd8]))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]))
    }

    func testJPEGQualityChangesEncodedByteSize() throws {
        let width = 128, height = 128
        let context = try XCTUnwrap(CapturePresentation.context(size: CGSize(width: width, height: height)))
        for y in 0..<height {
            for x in 0..<width {
                let red = CGFloat((x * 29 + y * 71) % 255) / 255
                let green = CGFloat((x * 83 + y * 11) % 255) / 255
                context.setFillColor(CGColor(red: red, green: green, blue: 1 - red, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let source = try XCTUnwrap(context.makeImage())
        var settings = CaptureExportSettings(); settings.format = .jpeg; settings.quality = 0.1
        let low = try settings.encode(source)
        settings.quality = 1
        let high = try settings.encode(source)
        XCTAssertGreaterThan(high.count, low.count)
    }

    func testInvalidExportSettingsRejectWithoutProducingBytes() throws {
        let source = try makeSource()
        var settings = CaptureExportSettings(); settings.width = 32_769
        XCTAssertThrowsError(try settings.encode(source))
        settings.width = nil; settings.quality = .infinity
        XCTAssertThrowsError(try settings.encode(source))
    }

    func testRecentDimensionsPreserveTheNewImagesAspectRatio() {
        var settings = CaptureExportSettings()
        settings.width = 640; settings.height = 480
        settings.matchAspectRatio(to: CGSize(width: 900, height: 1600))
        XCTAssertEqual(settings.width, 640)
        XCTAssertEqual(settings.height, 1138)
        settings.height = 200
        settings.matchAspectRatio(to: CGSize(width: 900, height: 1600), usingWidth: false)
        XCTAssertEqual(settings.width, 113)
        XCTAssertEqual(settings.height, 200)
        settings.keepAspectRatio = false
        settings.matchAspectRatio(to: CGSize(width: 1600, height: 900))
        XCTAssertEqual(settings.width, 113)
        XCTAssertEqual(settings.height, 200)
    }

    func testAspectRatioRestorationHandlesOriginalSizeAndHeightOnly() {
        var settings = CaptureExportSettings()
        settings.matchAspectRatio(to: CGSize(width: 48, height: 32))
        XCTAssertNil(settings.width); XCTAssertNil(settings.height)
        settings.height = 16
        settings.matchAspectRatio(to: CGSize(width: 48, height: 32))
        XCTAssertEqual(settings.width, 24)
        XCTAssertEqual(settings.height, 16)
        settings.width = 32_768
        settings.matchAspectRatio(to: CGSize(width: 1, height: 32_768))
        XCTAssertNil(settings.outputSize(for: CGSize(width: 1, height: 32_768)))
    }

    func testMissingBackgroundPreviewReturnsRepairableResourceError() async throws {
        let source = CaptureExportImage(image: try makeSource())
        var presentation = CapturePresentation()
        presentation.background = .image
        do {
            _ = try await CaptureExportWorker.shared.render(source, presentation: presentation)
            XCTFail("A missing custom background must not render")
        } catch CapturePresentationError.missingBackground { }
    }

    func testCancelledWorkerDoesNotReturnEncodedPreview() async throws {
        let source = CaptureExportImage(image: try makeSource())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptureExportWorker.shared.encode(source, settings: CaptureExportSettings())
        }
        do { _ = try await task.value; XCTFail("Cancelled request must not publish bytes") }
        catch is CancellationError { }
    }

    private func makeSource() throws -> CGImage {
        let context = try XCTUnwrap(CapturePresentation.context(size: CGSize(width: 48, height: 32)))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 16, y: 8, width: 16, height: 16))
        return try XCTUnwrap(context.makeImage())
    }
}
