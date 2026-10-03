import AppKit
import CoreImage

/// The input is the already-composited image immediately below this annotation.
enum CaptureBlur {
    static func image(from source: CGImage, normalizedRect: CGRect, radius: CGFloat) -> CGImage? {
        let rect = CapturePixelation.cropRect(for: normalizedRect, pixelSize: CGSize(width: source.width, height: source.height))
        guard rect.width > 0, rect.height > 0, let crop = source.cropping(to: rect) else { return nil }
        let input = CIImage(cgImage: crop)
        let result = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(60, max(1, radius))]).cropped(to: input.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(result, from: input.extent)
    }
}
