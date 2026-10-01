import AppKit
import XCTest
@testable import CaptureLab

final class CaptureImageCropTests: XCTestCase {
    func testFractionalSelectionIncludesAllTouchedSourcePixels() {
        XCTAssertEqual(
            CaptureImageCrop.pixelRect(
                CGRect(x: 0.105, y: 0.205, width: 0.20, height: 0.30),
                pixelSize: CGSize(width: 100, height: 80)
            ),
            CGRect(x: 10, y: 16, width: 21, height: 25)
        )
    }

    func testPartiallyOutsideSelectionClampsToImageBounds() {
        XCTAssertEqual(
            CaptureImageCrop.pixelRect(
                CGRect(x: -0.25, y: 0.75, width: 0.75, height: 0.50),
                pixelSize: CGSize(width: 80, height: 60)
            ),
            CGRect(x: 0, y: 45, width: 40, height: 15)
        )
    }

    func testEmptyOutsideAndNonfiniteSelectionsAreRejected() {
        let selections: [CGRect] = [
            .zero,
            CGRect(x: 0.2, y: 0.2, width: 0, height: 0.5),
            CGRect(x: 1.1, y: 0.2, width: 0.5, height: 0.5),
            CGRect(x: -1, y: -1, width: 0.5, height: 0.5),
            CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0, y: CGFloat.infinity, width: 0.5, height: 0.5),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 0.5),
            CGRect(x: 0, y: 0, width: 0.5, height: CGFloat.nan)
        ]
        for selection in selections {
            XCTAssertNil(
                CaptureImageCrop.pixelRect(selection, pixelSize: CGSize(width: 80, height: 60)),
                "Unexpected crop for \(selection)"
            )
        }
    }

    func testInvalidPixelDimensionsAreRejected() {
        let dimensions: [CGSize] = [
            .zero,
            CGSize(width: -10, height: 20),
            CGSize(width: 10, height: 0),
            CGSize(width: CGFloat.nan, height: 20),
            CGSize(width: CGFloat.infinity, height: 20),
            CGSize(width: 10, height: CGFloat.infinity)
        ]
        for size in dimensions {
            XCTAssertNil(
                CaptureImageCrop.pixelRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), pixelSize: size),
                "Unexpected crop for \(size)"
            )
        }
    }

    func testCropUsesTopLeftPixelOriginAndPreservesRetinaScale() throws {
        let source = try makeStripedImage(pixelWidth: 80, pixelHeight: 60, logicalSize: CGSize(width: 40, height: 30))
        let top = try XCTUnwrap(CaptureImageCrop.crop(
            source,
            selection: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)
        ))
        let bottom = try XCTUnwrap(CaptureImageCrop.crop(
            source,
            selection: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)
        ))

        XCTAssertEqual(top.captureLabPixelSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(top.size, CGSize(width: 20, height: 15))
        XCTAssertEqual(bottom.captureLabPixelSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(bottom.size, CGSize(width: 20, height: 15))

        let topBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(top.captureLabCGImage()))
        let bottomBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(bottom.captureLabCGImage()))
        for point in [(0, 0), (20, 15), (39, 29)] {
            let topColor = try XCTUnwrap(topBitmap.colorAt(x: point.0, y: point.1))
            let bottomColor = try XCTUnwrap(bottomBitmap.colorAt(x: point.0, y: point.1))
            XCTAssertEqual(topColor.redComponent, 1, accuracy: 0.01)
            XCTAssertEqual(topColor.blueComponent, 0, accuracy: 0.01)
            XCTAssertEqual(bottomColor.redComponent, 0, accuracy: 0.01)
            XCTAssertEqual(bottomColor.blueComponent, 1, accuracy: 0.01)
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(top.captureLabPNGData())))
        XCTAssertEqual(png.pixelsWide, 40)
        XCTAssertEqual(png.pixelsHigh, 30)
    }

    func testCropRejectsInvalidSelectionWithoutMutatingSource() throws {
        let source = try makeStripedImage(pixelWidth: 80, pixelHeight: 60, logicalSize: CGSize(width: 40, height: 30))
        let originalPNG = try XCTUnwrap(source.captureLabPNGData())

        XCTAssertNil(CaptureImageCrop.crop(source, selection: .zero))
        XCTAssertNil(CaptureImageCrop.crop(source, selection: CGRect(x: 2, y: 0, width: 0.5, height: 0.5)))
        XCTAssertEqual(source.captureLabPNGData(), originalPNG)
        XCTAssertEqual(source.size, CGSize(width: 40, height: 30))
    }

    private func makeStripedImage(pixelWidth: Int, pixelHeight: Int, logicalSize: CGSize) throws -> NSImage {
        var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let offset = (y * pixelWidth + x) * 4
                bytes[offset + (y < pixelHeight / 2 ? 0 : 2)] = 255
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixelWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = logicalSize
        let image = NSImage(size: logicalSize)
        image.addRepresentation(representation)
        return image
    }
}
