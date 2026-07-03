import CoreGraphics

enum CaptureGeometry {
    static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0
        else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    static func normalizedRect(from displayRect: CGRect, in imageDisplayRect: CGRect) -> CGRect {
        guard imageDisplayRect.width > 0, imageDisplayRect.height > 0 else {
            return .zero
        }
        return CGRect(
            x: (displayRect.minX - imageDisplayRect.minX) / imageDisplayRect.width,
            y: (displayRect.minY - imageDisplayRect.minY) / imageDisplayRect.height,
            width: displayRect.width / imageDisplayRect.width,
            height: displayRect.height / imageDisplayRect.height
        )
        .standardized
        .clampedToUnit()
    }

    static func normalizedPoint(from point: CGPoint, in imageDisplayRect: CGRect) -> CGPoint {
        guard imageDisplayRect.width > 0, imageDisplayRect.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: (point.x - imageDisplayRect.minX) / imageDisplayRect.width,
            y: (point.y - imageDisplayRect.minY) / imageDisplayRect.height
        )
        .clampedToUnit()
    }

    static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
