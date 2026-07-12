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

    func testPixelatedImageConvertsIndexedColorSpaceToSRGB() throws {
        let source = try makeIndexedImage(width: 24, height: 12)
        XCTAssertEqual(source.colorSpace?.model, .indexed)

        let pixelated = try XCTUnwrap(CapturePixelation.pixelatedImage(
            from: source,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            blockSize: 3
        ))

        XCTAssertEqual(pixelated.width, 24)
        XCTAssertEqual(pixelated.height, 12)
        XCTAssertEqual(pixelated.colorSpace?.model, .rgb)
        let color = try averageRGBA(in: pixelated)
        XCTAssertGreaterThan(color.red + color.blue, 80)
        XCTAssertEqual(color.alpha, 255)
        try assertEveryPixelOpaque(pixelated)
    }

    func testPixelatedImageConvertsCMYKColorSpaceToSRGB() throws {
        let source = try makeCMYKImage(width: 18, height: 10)
        XCTAssertEqual(source.colorSpace?.model, .cmyk)

        let pixelated = try XCTUnwrap(CapturePixelation.pixelatedImage(
            from: source,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            blockSize: 3
        ))

        XCTAssertEqual(pixelated.width, 18)
        XCTAssertEqual(pixelated.height, 10)
        XCTAssertEqual(pixelated.colorSpace?.model, .rgb)
        let color = try averageRGBA(in: pixelated)
        XCTAssertGreaterThan(color.red + color.green + color.blue, 40)
        XCTAssertEqual(color.alpha, 255)
        try assertEveryPixelOpaque(pixelated)
    }

    func testConversionFailureReturnsOpaqueFailClosedPixels() throws {
        let source = try makeStripedImage(width: 20, height: 12)
        let pixelated = try XCTUnwrap(CapturePixelation.pixelatedImage(
            from: source,
            normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            blockSize: 3,
            colorConverter: { _ in nil }
        ))

        XCTAssertEqual(pixelated.width, 10)
        XCTAssertEqual(pixelated.height, 6)
        let color = try averageRGBA(in: pixelated)
        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0)
        XCTAssertEqual(color.alpha, 255)
        try assertEveryPixelOpaque(pixelated)
    }

    func testTransparentSourceIsCompositedIntoOpaqueMosaic() throws {
        let source = try makeTransparentImage(width: 16, height: 12)
        let pixelated = try XCTUnwrap(CapturePixelation.pixelatedImage(
            from: source,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            blockSize: 4
        ))

        try assertEveryPixelOpaque(pixelated)
    }

    func testPreviewPixelationUsesRequestedDisplaySizeAndStaysOpaque() throws {
        let source = try makeTransparentImage(width: 120, height: 80)
        let preview = try XCTUnwrap(CapturePixelation.previewPixelatedImage(
            from: source,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.75, height: 0.75),
            outputPixelSize: CGSize(width: 30, height: 20),
            blockSize: 6
        ))

        XCTAssertEqual(preview.width, 30)
        XCTAssertEqual(preview.height, 20)
        try assertEveryPixelOpaque(preview)
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

    private func makeIndexedImage(width: Int, height: Int) throws -> CGImage {
        let indices = (0..<(width * height)).map { UInt8(($0 / width) % 2) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(indices) as CFData))
        let baseSpace = CGColorSpaceCreateDeviceRGB()
        let colorTable: [UInt8] = [
            255, 0, 0,
            0, 0, 255
        ]
        let indexedSpace = try XCTUnwrap(colorTable.withUnsafeBufferPointer { table in
            CGColorSpace(
                indexedBaseSpace: baseSpace,
                last: 1,
                colorTable: table.baseAddress!
            )
        })
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: indexedSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeCMYKImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = 0
            bytes[index + 1] = 255
            bytes[index + 2] = 255
            bytes[index + 3] = 0
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceCMYK(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeTransparentImage(width: Int, height: Int) throws -> CGImage {
        let bytes = [UInt8](repeating: 0, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
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

    private func assertEveryPixelOpaque(
        _ image: CGImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bytes = try rgbaBytes(in: image)
        for index in stride(from: 3, to: bytes.count, by: 4) {
            XCTAssertEqual(bytes[index], 255, file: file, line: line)
        }
    }

    private func averageRGBA(in image: CGImage) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let width = image.width
        let height = image.height
        let bytes = try rgbaBytes(in: image)

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

    private func rgbaBytes(in image: CGImage) throws -> [UInt8] {
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
        return bytes
    }
}
