import AppKit

/// Annotation metrics expressed in the coordinate space currently being drawn.
///
/// Export passes the source pixel size as both arguments. The canvas passes the
/// source pixel size plus the displayed image size, so every metric receives the
/// same zoom transform as the annotation geometry.
struct CaptureAnnotationStyle {
    static let mosaicOpacity: CGFloat = 1

    let sourcePixelSize: CGSize
    let renderedImageSize: CGSize
    var appearance: CaptureAnnotationAppearance = .init()

    var color: NSColor { appearance.color?.nsColor ?? .systemRed }
    var highlightColor: NSColor { appearance.color?.nsColor ?? .systemYellow }

    var counterTextColor: NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .black : .white
    }

    private var renderedScale: CGFloat {
        let widthScale = renderedImageSize.width / max(sourcePixelSize.width, 1)
        let heightScale = renderedImageSize.height / max(sourcePixelSize.height, 1)
        return max(0.0001, min(widthScale, heightScale))
    }

    private var sourceMinimumDimension: CGFloat {
        max(1, min(sourcePixelSize.width, sourcePixelSize.height))
    }

    var lineWidth: CGFloat {
        (appearance.lineWidth ?? max(3, sourceMinimumDimension * 0.004)) * renderedScale
    }

    var brushWidth: CGFloat {
        (appearance.lineWidth ?? max(4, sourceMinimumDimension * 0.005)) * renderedScale
    }

    var arrowHeadLength: CGFloat {
        max(14 * renderedScale, lineWidth * 4)
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
        appearance.fontSize.map { $0 * renderedScale }
            ?? max(14 * renderedScale, min(44 * renderedScale, rect.height * 0.46))
    }

    func counterFontSize(for diameter: CGFloat, text: String = "1") -> CGFloat {
        // Resizing a counter can make its circle smaller than the requested
        // font. Fit the complete label, including multi-digit numbers, inside
        // the circle. Measure in source pixels so zoom only scales the result.
        let sourceDiameter = diameter / renderedScale
        let requestedSize = appearance.fontSize ?? max(12, sourceDiameter * 0.48)
        let font = NSFont.systemFont(ofSize: requestedSize, weight: .bold)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let diagonal = hypot(measured.width, max(measured.height, requestedSize * 1.18))
        let availableDiameter = max(1, sourceDiameter - 4)
        return requestedSize * min(1, availableDiameter / max(diagonal, 1)) * renderedScale
    }
}
