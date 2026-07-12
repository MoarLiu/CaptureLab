import CoreGraphics

/// Annotation metrics expressed in the coordinate space currently being drawn.
///
/// Export passes the source pixel size as both arguments. The canvas passes the
/// source pixel size plus the displayed image size, so every metric receives the
/// same zoom transform as the annotation geometry.
struct CaptureAnnotationStyle {
    static let mosaicOpacity: CGFloat = 1

    let sourcePixelSize: CGSize
    let renderedImageSize: CGSize

    private var renderedScale: CGFloat {
        let widthScale = renderedImageSize.width / max(sourcePixelSize.width, 1)
        let heightScale = renderedImageSize.height / max(sourcePixelSize.height, 1)
        return max(0.0001, min(widthScale, heightScale))
    }

    private var sourceMinimumDimension: CGFloat {
        max(1, min(sourcePixelSize.width, sourcePixelSize.height))
    }

    var lineWidth: CGFloat {
        max(3, sourceMinimumDimension * 0.004) * renderedScale
    }

    var brushWidth: CGFloat {
        max(4, sourceMinimumDimension * 0.005) * renderedScale
    }

    var arrowHeadLength: CGFloat {
        max(14, max(3, sourceMinimumDimension * 0.004) * 4) * renderedScale
    }

    let arrowHeadAngle: CGFloat = .pi / 7

    var minimumCounterDiameter: CGFloat {
        16 * renderedScale
    }

    var textInset: CGFloat {
        2 * renderedScale
    }

    var highlightCornerRadius: CGFloat {
        2 * renderedScale
    }

    func textFontSize(for rect: CGRect) -> CGFloat {
        max(14 * renderedScale, min(44 * renderedScale, rect.height * 0.46))
    }

    func counterFontSize(for diameter: CGFloat) -> CGFloat {
        max(12 * renderedScale, diameter * 0.48)
    }
}
