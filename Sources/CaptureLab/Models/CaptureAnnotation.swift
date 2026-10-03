import CoreGraphics
import Foundation

enum CaptureTool: String, CaseIterable, Identifiable {
    case select
    case crop
    case arrow
    case line
    case rectangle
    case ellipse
    case filledRectangle
    case curvedArrow
    case spotlight
    case blur
    case counter
    case brush
    case text
    case highlight
    case mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop:
            return L10n.cropImage
        case .select:
            return L10n.toolSelect
        case .arrow:
            return L10n.toolArrow
        case .line:
            return L10n.toolLine
        case .rectangle:
            return L10n.toolBox
        case .ellipse:
            return L10n.text(en: "Ellipse", zh: "椭圆")
        case .filledRectangle:
            return L10n.text(en: "Filled Rectangle", zh: "实心矩形")
        case .curvedArrow:
            return L10n.text(en: "Curved Arrow", zh: "曲线箭头")
        case .spotlight:
            return L10n.text(en: "Spotlight", zh: "聚光灯")
        case .blur:
            return L10n.text(en: "Blur", zh: "模糊")
        case .counter:
            return L10n.toolCounter
        case .brush:
            return L10n.toolBrush
        case .text:
            return L10n.toolText
        case .highlight:
            return L10n.toolTextHighlight
        case .mosaic:
            return L10n.toolMosaic
        }
    }

    var systemImage: String {
        switch self {
        case .crop:
            return "crop"
        case .select:
            return "cursorarrow"
        case .arrow:
            return "arrow.up.right"
        case .line:
            return "line.diagonal"
        case .rectangle:
            return "rectangle"
        case .ellipse:
            return "oval"
        case .filledRectangle:
            return "rectangle.fill"
        case .curvedArrow:
            return "arrow.turn.up.right"
        case .spotlight:
            return "flashlight.on.fill"
        case .blur:
            return "drop.halffull"
        case .counter:
            return "number.circle"
        case .brush:
            return "pencil.tip"
        case .text:
            return "character.cursor.ibeam"
        case .highlight:
            return "highlighter"
        case .mosaic:
            return "square.grid.3x3.fill"
        }
    }

    var annotationKind: CaptureAnnotation.Kind? {
        switch self {
        case .select, .crop:
            return nil
        case .arrow:
            return .arrow
        case .line:
            return .line
        case .rectangle:
            return .rectangle
        case .ellipse:
            return .ellipse
        case .filledRectangle:
            return .filledRectangle
        case .curvedArrow:
            return .curvedArrow
        case .spotlight:
            return .spotlight
        case .blur:
            return .blur
        case .counter:
            return .counter
        case .brush:
            return .brush
        case .text:
            return .text
        case .highlight:
            return .highlight
        case .mosaic:
            return .mosaic
        }
    }
}

struct CaptureAnnotationPoint: Hashable, Codable {
    var x: CGFloat
    var y: CGFloat

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct CaptureAnnotation: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case arrow
        case line
        case rectangle
        case ellipse
        case filledRectangle
        case curvedArrow
        case spotlight
        case blur
        case counter
        case brush
        case text
        case highlight
        case mosaic

        var displayTitle: String {
            switch self {
            case .arrow:
                return L10n.toolArrow
            case .line:
                return L10n.toolLine
            case .rectangle:
                return L10n.toolBox
            case .ellipse:
                return L10n.text(en: "Ellipse", zh: "椭圆")
            case .filledRectangle:
                return L10n.text(en: "Filled Rectangle", zh: "实心矩形")
            case .curvedArrow:
                return L10n.text(en: "Curved Arrow", zh: "曲线箭头")
            case .spotlight:
                return L10n.text(en: "Spotlight", zh: "聚光灯")
            case .blur:
                return L10n.text(en: "Blur", zh: "模糊")
            case .counter:
                return L10n.toolCounter
            case .brush:
                return L10n.toolBrush
            case .text:
                return L10n.toolText
            case .highlight:
                return L10n.toolTextHighlight
            case .mosaic:
                return L10n.toolMosaic
            }
        }
    }

    var id: UUID
    var kind: Kind
    var normalizedRect: CGRect
    var normalizedPoints: [CaptureAnnotationPoint]
    var text: String
    var appearance: CaptureAnnotationAppearance

    init(
        id: UUID = UUID(),
        kind: Kind,
        normalizedRect: CGRect,
        normalizedPoints: [CaptureAnnotationPoint] = [],
        text: String = "",
        appearance: CaptureAnnotationAppearance = .init()
    ) {
        self.id = id
        self.kind = kind
        self.normalizedRect = normalizedRect.standardized.clampedToUnit()
        self.normalizedPoints = normalizedPoints.map { CaptureAnnotationPoint($0.cgPoint.clampedToUnit()) }
        self.text = text
        self.appearance = appearance
    }

    static func arrow(start: CGPoint, end: CGPoint) -> CaptureAnnotation {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        return CaptureAnnotation(
            kind: .arrow,
            normalizedRect: rect,
            normalizedPoints: [CaptureAnnotationPoint(start), CaptureAnnotationPoint(end)]
        )
    }

    /// Endpoints stay at indices 0/1; index 2 is the quadratic control handle.
    static func curvedArrow(start: CGPoint, end: CGPoint, control: CGPoint? = nil) -> CaptureAnnotation {
        let control = control ?? CGPoint(x: (start.x + end.x) / 2 + (end.y - start.y) * 0.25,
                                         y: (start.y + end.y) / 2 - (end.x - start.x) * 0.25).clampedToUnit()
        let points = [start, end, control]
        return CaptureAnnotation(kind: .curvedArrow, normalizedRect: .bounding(points),
                                 normalizedPoints: points.map(CaptureAnnotationPoint.init))
    }

    static func line(start: CGPoint, end: CGPoint) -> CaptureAnnotation {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        return CaptureAnnotation(
            kind: .line,
            normalizedRect: rect,
            normalizedPoints: [CaptureAnnotationPoint(start), CaptureAnnotationPoint(end)]
        )
    }

    static func brush(points: [CGPoint]) -> CaptureAnnotation {
        let clamped = points.map { $0.clampedToUnit() }
        return CaptureAnnotation(
            kind: .brush,
            normalizedRect: CGRect.bounding(clamped),
            normalizedPoints: clamped.map(CaptureAnnotationPoint.init)
        )
    }

    static func text(normalizedRect: CGRect, text: String = L10n.defaultAnnotationText) -> CaptureAnnotation {
        CaptureAnnotation(kind: .text, normalizedRect: normalizedRect, text: text)
    }

    func rect(in displayRect: CGRect) -> CGRect {
        CGRect(
            x: displayRect.minX + normalizedRect.minX * displayRect.width,
            y: displayRect.minY + normalizedRect.minY * displayRect.height,
            width: normalizedRect.width * displayRect.width,
            height: normalizedRect.height * displayRect.height
        )
    }

    func imageRect(in imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * imageSize.width,
            y: (1 - normalizedRect.maxY) * imageSize.height,
            width: normalizedRect.width * imageSize.width,
            height: normalizedRect.height * imageSize.height
        )
    }

    func points(in displayRect: CGRect) -> [CGPoint] {
        normalizedPoints.map { point in
            CGPoint(
                x: displayRect.minX + point.x * displayRect.width,
                y: displayRect.minY + point.y * displayRect.height
            )
        }
    }

    func imagePoints(in imageSize: CGSize) -> [CGPoint] {
        normalizedPoints.map { point in
            CGPoint(
                x: point.x * imageSize.width,
                y: (1 - point.y) * imageSize.height
            )
        }
    }

    func withNormalizedRect(_ rect: CGRect) -> CaptureAnnotation {
        CaptureAnnotation(
            id: id,
            kind: kind,
            normalizedRect: rect,
            normalizedPoints: normalizedPoints,
            text: text,
            appearance: appearance
        )
    }

    func withNormalizedPoints(_ points: [CGPoint]) -> CaptureAnnotation {
        CaptureAnnotation(
            id: id,
            kind: kind,
            normalizedRect: CGRect.bounding(points),
            normalizedPoints: points.map(CaptureAnnotationPoint.init),
            text: text,
            appearance: appearance
        )
    }

    func replacingPoint(at index: Int, with point: CGPoint) -> CaptureAnnotation {
        var points = normalizedPoints.map(\.cgPoint)
        guard points.indices.contains(index) else {
            return self
        }
        points[index] = point.clampedToUnit()
        return withNormalizedPoints(points)
    }

    func translatedBy(dx: CGFloat, dy: CGFloat) -> CaptureAnnotation {
        let bounds = normalizedBounds
        let adjustedDX = min(max(dx, -bounds.minX), 1 - bounds.maxX)
        let adjustedDY = min(max(dy, -bounds.minY), 1 - bounds.maxY)

        switch kind {
        case .arrow, .curvedArrow, .line, .brush:
            let points = normalizedPoints.map {
                CGPoint(x: $0.x + adjustedDX, y: $0.y + adjustedDY).clampedToUnit()
            }
            return withNormalizedPoints(points)
        case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic:
            return withNormalizedRect(normalizedRect.offsetBy(dx: adjustedDX, dy: adjustedDY))
        }
    }

    func scaledToNormalizedRect(_ targetRect: CGRect) -> CaptureAnnotation {
        let target = targetRect.clampedToUnit()
        switch kind {
        case .arrow, .curvedArrow, .line, .brush:
            let points = normalizedPoints.map(\.cgPoint)
            let bounds = CGRect.bounding(points)
            guard !points.isEmpty else {
                return self
            }
            let scaled = points.map { point in
                let xRatio = bounds.width > 0.0001 ? (point.x - bounds.minX) / bounds.width : 0.5
                let yRatio = bounds.height > 0.0001 ? (point.y - bounds.minY) / bounds.height : 0.5
                return CGPoint(
                    x: target.minX + target.width * xRatio,
                    y: target.minY + target.height * yRatio
                )
                .clampedToUnit()
            }
            return withNormalizedPoints(scaled)
        case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic:
            return withNormalizedRect(target)
        }
    }

    var normalizedBounds: CGRect {
        switch kind {
        case .arrow, .curvedArrow, .line, .brush:
            let points = normalizedPoints.map(\.cgPoint)
            return points.isEmpty ? normalizedRect : CGRect.bounding(points)
        case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic:
            return normalizedRect
        }
    }
}

extension CGRect {
    func clampedToUnit() -> CGRect {
        let minX = min(max(self.minX, 0), 1)
        let minY = min(max(self.minY, 0), 1)
        let maxX = min(max(self.maxX, 0), 1)
        let maxY = min(max(self.maxY, 0), 1)
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    static func bounding(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else {
            return .zero
        }
        let minX = points.reduce(first.x) { min($0, $1.x) }
        let minY = points.reduce(first.y) { min($0, $1.y) }
        let maxX = points.reduce(first.x) { max($0, $1.x) }
        let maxY = points.reduce(first.y) { max($0, $1.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).clampedToUnit()
    }
}

extension CGPoint {
    func clampedToUnit() -> CGPoint {
        CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
