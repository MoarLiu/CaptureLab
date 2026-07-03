import CoreGraphics
import Foundation

enum CaptureTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case rectangle
    case brush
    case text
    case mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select:
            return L10n.toolSelect
        case .arrow:
            return L10n.toolArrow
        case .rectangle:
            return L10n.toolBox
        case .brush:
            return L10n.toolBrush
        case .text:
            return L10n.toolText
        case .mosaic:
            return L10n.toolMosaic
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            return "cursorarrow"
        case .arrow:
            return "arrow.up.right"
        case .rectangle:
            return "rectangle"
        case .brush:
            return "pencil.tip"
        case .text:
            return "character.cursor.ibeam"
        case .mosaic:
            return "square.grid.3x3.fill"
        }
    }

    var annotationKind: CaptureAnnotation.Kind? {
        switch self {
        case .select:
            return nil
        case .arrow:
            return .arrow
        case .rectangle:
            return .rectangle
        case .brush:
            return .brush
        case .text:
            return .text
        case .mosaic:
            return .mosaic
        }
    }
}

struct CaptureAnnotationPoint: Hashable {
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

struct CaptureAnnotation: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case arrow
        case rectangle
        case brush
        case text
        case mosaic

        var displayTitle: String {
            switch self {
            case .arrow:
                return L10n.toolArrow
            case .rectangle:
                return L10n.toolBox
            case .brush:
                return L10n.toolBrush
            case .text:
                return L10n.toolText
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

    init(
        id: UUID = UUID(),
        kind: Kind,
        normalizedRect: CGRect,
        normalizedPoints: [CaptureAnnotationPoint] = [],
        text: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.normalizedRect = normalizedRect.standardized.clampedToUnit()
        self.normalizedPoints = normalizedPoints.map { CaptureAnnotationPoint($0.cgPoint.clampedToUnit()) }
        self.text = text
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
            text: text
        )
    }

    func withNormalizedPoints(_ points: [CGPoint]) -> CaptureAnnotation {
        CaptureAnnotation(
            id: id,
            kind: kind,
            normalizedRect: CGRect.bounding(points),
            normalizedPoints: points.map(CaptureAnnotationPoint.init),
            text: text
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
        case .arrow, .brush:
            let points = normalizedPoints.map {
                CGPoint(x: $0.x + adjustedDX, y: $0.y + adjustedDY).clampedToUnit()
            }
            return withNormalizedPoints(points)
        case .rectangle, .text, .mosaic:
            return withNormalizedRect(normalizedRect.offsetBy(dx: adjustedDX, dy: adjustedDY))
        }
    }

    func scaledToNormalizedRect(_ targetRect: CGRect) -> CaptureAnnotation {
        let target = targetRect.clampedToUnit()
        switch kind {
        case .arrow, .brush:
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
        case .rectangle, .text, .mosaic:
            return withNormalizedRect(target)
        }
    }

    var normalizedBounds: CGRect {
        switch kind {
        case .arrow, .brush:
            let points = normalizedPoints.map(\.cgPoint)
            return points.isEmpty ? normalizedRect : CGRect.bounding(points)
        case .rectangle, .text, .mosaic:
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
