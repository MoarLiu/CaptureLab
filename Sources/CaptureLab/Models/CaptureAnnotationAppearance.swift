import AppKit

struct CaptureAnnotationColor: Hashable, Codable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemRed
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

struct CaptureAnnotationAppearance: Hashable, Codable {
    // Nil retains the original automatic sizing and tool-specific color.
    var color: CaptureAnnotationColor?
    var lineWidth: CGFloat?
    var fontSize: CGFloat?

    var arrowStyle: CaptureArrowStyle?
    var shapeFill: CaptureShapeFill?
    var fillColor: CaptureAnnotationColor?
    var fontFamily: String?
    var fontWeight: CaptureFontWeight?
    var textAlignment: CaptureTextAlignment?
    var textBackgroundColor: CaptureAnnotationColor?
    var textBorderColor: CaptureAnnotationColor?
    var blurRadius: CGFloat?
    var spotlightOpacity: CGFloat?
    var brushSmoothing: CGFloat?
    var highlightTextAlignment: Bool?

    static let editorDefault = CaptureAnnotationAppearance(lineWidth: 4, fontSize: 24, brushSmoothing: 0.65)
}

extension CaptureAnnotation {
    /// Grow text geometry along with its font, rather than clipping a larger
    /// font into the old creation box. Export and preview consume this same rect.
    func fittingFontBounds(in pixelSize: CGSize) -> CaptureAnnotation {
        guard kind == .text || kind == .counter,
              let fontSize = appearance.fontSize, fontSize.isFinite, fontSize > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return self }
        let font = kind == .counter ? NSFont.systemFont(ofSize: fontSize, weight: .bold) : appearance.textFont(size: fontSize)
        let value = text.isEmpty ? (kind == .counter ? "1" : L10n.defaultAnnotationText) : text
        let measured = (value as NSString).size(withAttributes: [.font: font])
        var required = CGSize(width: measured.width + 8, height: max(measured.height, fontSize * 1.25) + 4)
        if kind == .counter {
            let diameter = max(required.width, required.height) + 8
            required = CGSize(width: diameter, height: diameter)
        }
        let width = min(1, max(normalizedRect.width, required.width / pixelSize.width))
        let height = min(1, max(normalizedRect.height, required.height / pixelSize.height))
        return withNormalizedRect(CGRect(
            x: max(0, min(1 - width, normalizedRect.midX - width / 2)),
            y: max(0, min(1 - height, normalizedRect.midY - height / 2)),
            width: width,
            height: height
        ))
    }
}
