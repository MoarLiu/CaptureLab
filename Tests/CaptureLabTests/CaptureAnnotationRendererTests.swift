import AppKit
import XCTest
@testable import CaptureLab

final class CaptureAnnotationRendererTests: XCTestCase {
    func testAnnotatedImageAndPNGKeepSourceCGImagePixelDimensions() throws {
        let cases: [(pixels: CGSize, logical: CGSize)] = [
            (CGSize(width: 300, height: 150), CGSize(width: 100, height: 50)),
            (CGSize(width: 200, height: 100), CGSize(width: 100, height: 50)),
            (CGSize(width: 100, height: 50), CGSize(width: 300, height: 150))
        ]
        let annotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        )

        for testCase in cases {
            let source = try makeImage(
                pixelWidth: Int(testCase.pixels.width),
                pixelHeight: Int(testCase.pixels.height),
                logicalSize: testCase.logical
            )

            let unannotated = try XCTUnwrap(source.renderedWithCaptureLabAnnotations([]))
            let unannotatedCGImage = try XCTUnwrap(unannotated.captureLabCGImage())
            XCTAssertEqual(unannotatedCGImage.width, Int(testCase.pixels.width))
            XCTAssertEqual(unannotatedCGImage.height, Int(testCase.pixels.height))

            let unannotatedPNGData = try XCTUnwrap(source.captureLabPNGData())
            let unannotatedPNG = try XCTUnwrap(NSBitmapImageRep(data: unannotatedPNGData))
            XCTAssertEqual(unannotatedPNG.pixelsWide, Int(testCase.pixels.width))
            XCTAssertEqual(unannotatedPNG.pixelsHigh, Int(testCase.pixels.height))

            let rendered = try XCTUnwrap(source.renderedWithCaptureLabAnnotations([annotation]))
            let renderedCGImage = try XCTUnwrap(rendered.captureLabCGImage())
            XCTAssertEqual(renderedCGImage.width, Int(testCase.pixels.width))
            XCTAssertEqual(renderedCGImage.height, Int(testCase.pixels.height))

            let pngData = try XCTUnwrap(source.captureLabPNGData(annotations: [annotation]))
            let png = try XCTUnwrap(NSBitmapImageRep(data: pngData))
            XCTAssertEqual(png.pixelsWide, Int(testCase.pixels.width))
            XCTAssertEqual(png.pixelsHigh, Int(testCase.pixels.height))
        }
    }

    func testRendererPreservesTopBottomOrientationOfAsymmetricSource() throws {
        let sourceCGImage = try makeAsymmetricImage(pixelWidth: 100, pixelHeight: 80)
        let source = NSImage(cgImage: sourceCGImage, size: CGSize(width: 100, height: 80))
        let cornerAnnotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        )

        let rendered = try XCTUnwrap(source.renderedWithCaptureLabAnnotations([cornerAnnotation]))
        let output = try XCTUnwrap(rendered.captureLabCGImage())
        let sourceBitmap = NSBitmapImageRep(cgImage: sourceCGImage)
        let outputBitmap = NSBitmapImageRep(cgImage: output)
        let sourceFirstRowRegion = try XCTUnwrap(sourceBitmap.colorAt(x: 50, y: 10))
        let sourceLastRowRegion = try XCTUnwrap(sourceBitmap.colorAt(x: 50, y: 70))

        XCTAssertGreaterThan(
            abs(sourceFirstRowRegion.redComponent - sourceLastRowRegion.redComponent),
            0.9
        )
        XCTAssertGreaterThan(
            abs(sourceFirstRowRegion.blueComponent - sourceLastRowRegion.blueComponent),
            0.9
        )

        assertColor(
            try XCTUnwrap(outputBitmap.colorAt(x: 50, y: 10)),
            approximatelyEquals: sourceFirstRowRegion
        )
        assertColor(
            try XCTUnwrap(outputBitmap.colorAt(x: 50, y: 70)),
            approximatelyEquals: sourceLastRowRegion
        )
    }

    func testTopNormalizedAnnotationRendersAtTopOfPixelOutput() throws {
        let source = try makeImage(
            pixelWidth: 100,
            pixelHeight: 100,
            logicalSize: CGSize(width: 100, height: 100)
        )
        let highlight = CaptureAnnotation(
            kind: .highlight,
            normalizedRect: CGRect(x: 0.2, y: 0, width: 0.6, height: 0.25)
        )

        let rendered = try XCTUnwrap(source.renderedWithCaptureLabAnnotations([highlight]))
        let output = try XCTUnwrap(rendered.captureLabCGImage())
        let bitmap = NSBitmapImageRep(cgImage: output)
        // NSBitmapImageRep addresses encoded rows from the top, matching the
        // normalized annotation model and CGImage crop coordinates.
        let top = try XCTUnwrap(bitmap.colorAt(x: 50, y: 10))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 50, y: 90))

        XCTAssertGreaterThan(top.redComponent, bottom.redComponent + 0.1)
        XCTAssertGreaterThan(top.greenComponent, bottom.greenComponent + 0.1)
    }

    func testMosaicRegionIsOpaqueEvenWhenSourcePixelsAreTransparent() throws {
        let width = 12
        let height = 8
        let bytes = [UInt8](repeating: 0, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let sourceCGImage = try XCTUnwrap(CGImage(
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
        let source = NSImage(cgImage: sourceCGImage, size: CGSize(width: width, height: height))
        let mosaic = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        let rendered = try XCTUnwrap(source.renderedWithCaptureLabAnnotations([mosaic]))
        let output = try XCTUnwrap(rendered.captureLabCGImage())
        let bitmap = NSBitmapImageRep(cgImage: output)
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 1)
            }
        }
    }

    func testAnnotatedRendererNeverFallsBackToSourceWhenBitmapRenderingFails() throws {
        let source = try makeImage(
            pixelWidth: 64,
            pixelHeight: 48,
            logicalSize: CGSize(width: 64, height: 48)
        )
        let mosaic = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        )

        let rendered = source.renderedWithCaptureLabAnnotations(
            [mosaic],
            bitmapRenderer: { _, _ in nil }
        )

        XCTAssertNil(rendered)
    }

    func testPreviewStyleMetricsAreExactZoomTransformsOfExportMetrics() {
        let pixelSize = CGSize(width: 1200, height: 800)
        let export = CaptureAnnotationStyle(
            sourcePixelSize: pixelSize,
            renderedImageSize: pixelSize
        )
        let halfPreview = CaptureAnnotationStyle(
            sourcePixelSize: pixelSize,
            renderedImageSize: CGSize(width: 600, height: 400)
        )
        let doublePreview = CaptureAnnotationStyle(
            sourcePixelSize: pixelSize,
            renderedImageSize: CGSize(width: 2400, height: 1600)
        )

        XCTAssertEqual(halfPreview.lineWidth, export.lineWidth * 0.5, accuracy: 0.0001)
        XCTAssertEqual(halfPreview.brushWidth, export.brushWidth * 0.5, accuracy: 0.0001)
        XCTAssertEqual(halfPreview.arrowHeadLength, export.arrowHeadLength * 0.5, accuracy: 0.0001)
        XCTAssertEqual(halfPreview.minimumCounterDiameter, export.minimumCounterDiameter * 0.5, accuracy: 0.0001)
        XCTAssertEqual(doublePreview.lineWidth, export.lineWidth * 2, accuracy: 0.0001)
        XCTAssertEqual(doublePreview.brushWidth, export.brushWidth * 2, accuracy: 0.0001)
        XCTAssertEqual(doublePreview.arrowHeadLength, export.arrowHeadLength * 2, accuracy: 0.0001)

        let exportTextRect = CGRect(x: 0, y: 0, width: 400, height: 120)
        let previewTextRect = CGRect(x: 0, y: 0, width: 200, height: 60)
        XCTAssertEqual(
            halfPreview.textFontSize(for: previewTextRect),
            export.textFontSize(for: exportTextRect) * 0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            halfPreview.counterFontSize(for: 40),
            export.counterFontSize(for: 80) * 0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(CaptureAnnotationStyle.mosaicOpacity, 1)
    }

    private func makeImage(
        pixelWidth: Int,
        pixelHeight: Int,
        logicalSize: CGSize
    ) throws -> NSImage {
        var bytes = [UInt8](repeating: 255, count: pixelWidth * pixelHeight * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.35, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let cgImage = try XCTUnwrap(context.makeImage())
        return NSImage(cgImage: cgImage, size: logicalSize)
    }

    private func makeAsymmetricImage(pixelWidth: Int, pixelHeight: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight / 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(
            x: 0,
            y: pixelHeight / 2,
            width: pixelWidth,
            height: pixelHeight / 2
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func assertColor(
        _ color: NSColor,
        approximatelyEquals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualRGB = color.usingColorSpace(.sRGB) ?? color
        let expectedRGB = expected.usingColorSpace(.sRGB) ?? expected
        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actualRGB.alphaComponent, expectedRGB.alphaComponent, accuracy: 0.02, file: file, line: line)
    }
}
