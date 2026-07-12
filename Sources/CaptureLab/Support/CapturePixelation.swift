import AppKit
import CoreGraphics

enum CapturePixelation {
    static func cropRect(for normalizedRect: CGRect, pixelSize: CGSize) -> CGRect {
        let sourceBounds = CGRect(origin: .zero, size: pixelSize)
        // CGImage cropping uses image pixel coordinates; y=0 addresses the top row
        // for the pixel buffers CaptureLab receives from screenshots and images.
        let crop = CGRect(
            x: normalizedRect.minX * pixelSize.width,
            y: normalizedRect.minY * pixelSize.height,
            width: normalizedRect.width * pixelSize.width,
            height: normalizedRect.height * pixelSize.height
        )
        .integral
        .intersection(sourceBounds)

        return crop.isNull ? .zero : crop
    }

    static func pixelatedImage(from source: CGImage, normalizedRect: CGRect, blockSize: Int = 6) -> CGImage? {
        pixelatedImage(
            from: source,
            normalizedRect: normalizedRect,
            blockSize: blockSize,
            colorConverter: convertedToSRGB
        )
    }

    /// Internal overload keeps the failure path deterministic in regression
    /// tests. A valid crop always returns either a pixelated sRGB image or an
    /// opaque replacement; it never exposes the source region on conversion
    /// failure.
    static func pixelatedImage(
        from source: CGImage,
        normalizedRect: CGRect,
        blockSize: Int,
        colorConverter: (CGImage) -> CGImage?
    ) -> CGImage? {
        guard normalizedRect.width > 0,
              normalizedRect.height > 0
        else {
            return nil
        }

        let crop = cropRect(
            for: normalizedRect,
            pixelSize: CGSize(width: source.width, height: source.height)
        )
        guard crop.width >= 1,
              crop.height >= 1,
              let cropped = source.cropping(to: crop)
        else {
            return nil
        }

        guard let converted = colorConverter(cropped) else {
            return opaqueFailClosedImage(width: cropped.width, height: cropped.height)
        }

        return pixelatedImage(fromSRGB: converted, blockSize: blockSize)
            ?? opaqueFailClosedImage(width: cropped.width, height: cropped.height)
    }

    /// Builds a display-sized mosaic without allocating a second full-size
    /// copy of a high-resolution source crop. Export deliberately continues to
    /// use `pixelatedImage(from:normalizedRect:blockSize:)` so it retains the
    /// source crop's exact pixel dimensions.
    static func previewPixelatedImage(
        from source: CGImage,
        normalizedRect: CGRect,
        outputPixelSize: CGSize,
        blockSize: Int = 6
    ) -> CGImage? {
        guard normalizedRect.width > 0,
              normalizedRect.height > 0,
              outputPixelSize.width > 0,
              outputPixelSize.height > 0
        else {
            return nil
        }

        let crop = cropRect(
            for: normalizedRect,
            pixelSize: CGSize(width: source.width, height: source.height)
        )
        guard crop.width >= 1,
              crop.height >= 1,
              let cropped = source.cropping(to: crop)
        else {
            return nil
        }

        let outputWidth = max(1, min(cropped.width, Int(outputPixelSize.width.rounded(.up))))
        let outputHeight = max(1, min(cropped.height, Int(outputPixelSize.height.rounded(.up))))
        let block = max(1, blockSize)

        // A full-resolution mosaic first samples one color per block. Keep at
        // most that many samples when preparing the preview, then scale them
        // directly into the display-sized opaque sRGB result.
        let sampleWidth = max(1, min(outputWidth, cropped.width / block))
        let sampleHeight = max(1, min(outputHeight, cropped.height / block))
        guard let sampleContext = makeSRGBContext(width: sampleWidth, height: sampleHeight) else {
            return opaqueFailClosedImage(width: outputWidth, height: outputHeight)
        }
        sampleContext.interpolationQuality = .low
        sampleContext.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight)
        )

        guard let sampled = sampleContext.makeImage(),
              let outputContext = makeSRGBContext(width: outputWidth, height: outputHeight)
        else {
            return opaqueFailClosedImage(width: outputWidth, height: outputHeight)
        }
        outputContext.interpolationQuality = .none
        outputContext.draw(
            sampled,
            in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        )
        return outputContext.makeImage()
            ?? opaqueFailClosedImage(width: outputWidth, height: outputHeight)
    }

    static func opaqueFailClosedImage(width: Int, height: Int) -> CGImage? {
        guard width > 0,
              height > 0,
              let context = makeSRGBContext(width: width, height: height)
        else {
            return nil
        }

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func convertedToSRGB(_ source: CGImage) -> CGImage? {
        guard let context = makeSRGBContext(width: source.width, height: source.height) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()
    }

    private static func pixelatedImage(fromSRGB source: CGImage, blockSize: Int) -> CGImage? {
        let block = max(1, blockSize)
        let tinyWidth = max(1, source.width / block)
        let tinyHeight = max(1, source.height / block)

        guard let smallContext = makeSRGBContext(width: tinyWidth, height: tinyHeight) else {
            return nil
        }
        smallContext.interpolationQuality = .low
        smallContext.draw(source, in: CGRect(x: 0, y: 0, width: tinyWidth, height: tinyHeight))

        guard let small = smallContext.makeImage(),
              let outputContext = makeSRGBContext(width: source.width, height: source.height)
        else {
            return nil
        }

        outputContext.interpolationQuality = .none
        outputContext.draw(small, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return outputContext.makeImage()
    }

    private static func makeSRGBContext(width: Int, height: Int) -> CGContext? {
        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        // Mosaic output is a privacy boundary. Composite every source format,
        // including images with alpha, over opaque black before sampling.
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}
