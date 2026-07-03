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

        return pixelatedImage(from: cropped, blockSize: blockSize)
    }

    private static func pixelatedImage(from source: CGImage, blockSize: Int) -> CGImage? {
        let block = max(1, blockSize)
        let tinyWidth = max(1, source.width / block)
        let tinyHeight = max(1, source.height / block)
        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let smallContext = CGContext(
            data: nil,
            width: tinyWidth,
            height: tinyHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        smallContext.interpolationQuality = .low
        smallContext.draw(source, in: CGRect(x: 0, y: 0, width: tinyWidth, height: tinyHeight))

        guard let small = smallContext.makeImage(),
              let outputContext = CGContext(
                data: nil,
                width: source.width,
                height: source.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
              )
        else {
            return nil
        }

        outputContext.interpolationQuality = .none
        outputContext.draw(small, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return outputContext.makeImage()
    }
}
