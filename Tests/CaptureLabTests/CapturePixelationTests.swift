import AppKit
import XCTest
@testable import CaptureLab

final class CapturePixelationTests: XCTestCase {
    func testCropRectUsesTopOriginNormalizedCoordinates() {
        let crop = CapturePixelation.cropRect(
            for: CGRect(x: 0.25, y: 0.10, width: 0.50, height: 0.20),
            pixelSize: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(crop, CGRect(x: 25, y: 20, width: 50, height: 40))
    }

    func testPixelatedImageSamplesSelectedTopRegion() throws {
        let source = try makeStripedImage(width: 60, height: 40)
        let pixelated = try XCTUnwrap(CapturePixelation.pixelatedImage(
            from: source,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.5),
            blockSize: 6
        ))

        let color = try averageRGBA(in: pixelated)
        XCTAssertGreaterThan(color.red, 220)
        XCTAssertLessThan(color.blue, 40)
    }

    private func makeStripedImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if y < height / 2 {
                    bytes[index] = 255
                    bytes[index + 1] = 0
                    bytes[index + 2] = 0
                    bytes[index + 3] = 255
                } else {
                    bytes[index] = 0
                    bytes[index + 1] = 0
                    bytes[index + 2] = 255
                    bytes[index + 3] = 255
                }
            }
        }

        let data = Data(bytes)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func averageRGBA(in image: CGImage) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            red += Int(bytes[index])
            green += Int(bytes[index + 1])
            blue += Int(bytes[index + 2])
            alpha += Int(bytes[index + 3])
        }
        let count = width * height
        return (red / count, green / count, blue / count, alpha / count)
    }
}

