import AppKit

enum CaptureImageCrop {
    /// Normalized selections use the top-left origin, including on Retina images.
    static func pixelRect(_ selection: CGRect, pixelSize: CGSize) -> CGRect? {
        guard selection.origin.x.isFinite, selection.origin.y.isFinite,
              selection.width.isFinite, selection.height.isFinite,
              pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let rect = selection.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let left = floor(rect.minX * pixelSize.width + 0.0000001)
        let top = floor(rect.minY * pixelSize.height + 0.0000001)
        let right = min(pixelSize.width, ceil(rect.maxX * pixelSize.width - 0.0000001))
        let bottom = min(pixelSize.height, ceil(rect.maxY * pixelSize.height - 0.0000001))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func crop(_ image: NSImage, selection: CGRect) -> NSImage? {
        guard let source = image.captureLabCGImage(),
              let rect = pixelRect(selection, pixelSize: CGSize(width: source.width, height: source.height)),
              let cropped = source.cropping(to: rect) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cropped)
        let logicalSize = CGSize(
            width: rect.width * image.size.width / CGFloat(source.width),
            height: rect.height * image.size.height / CGFloat(source.height)
        )
        bitmap.size = logicalSize
        let output = NSImage(size: logicalSize)
        output.addRepresentation(bitmap)
        return output
    }
}
