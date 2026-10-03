import AppKit
import ImageIO

enum CaptureLayerComposition {
    /// Compose all image resources first. The caller then renders annotations
    /// onto this result, so redactions cover overlapping images as well.
    static func render(source: NSImage, layers: [CaptureImageLayer]) -> NSImage? {
        guard !layers.isEmpty else { return source }
        guard (try? CaptureLayerImport.validate(layers)) != nil,
              let base = source.captureLabCGImage(),
              let context = CGContext(data: nil, width: base.width, height: base.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: base.width, height: base.height)
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(origin: .zero, size: size))
        for layer in ordered(layers) {
            guard let imageSource = CGImageSourceCreateWithData(layer.pngData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
            let r = layer.normalizedRect
            context.saveGState()
            context.translateBy(x: r.midX * size.width, y: (1 - r.midY) * size.height)
            context.rotate(by: -layer.rotationDegrees * .pi / 180)
            context.draw(image, in: CGRect(x: -r.width * size.width / 2, y: -r.height * size.height / 2,
                                           width: r.width * size.width, height: r.height * size.height))
            context.restoreGState()
        }
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: source.size)
    }

    static func ordered(_ layers: [CaptureImageLayer]) -> [CaptureImageLayer] {
        // Preserve document order for ties, including projects written by
        // earlier clients; sorting must never randomly reorder equal z values.
        layers.enumerated().sorted { a, b in
            a.element.zIndex == b.element.zIndex ? a.offset < b.offset : a.element.zIndex < b.element.zIndex
        }.map(\.element)
    }
}

enum CaptureObjectArrangement: CaseIterable, Hashable {
    case alignLeft, alignCenter, alignRight, alignTop, alignMiddle, alignBottom
    case horizontal, vertical, distributeHorizontal, distributeVertical

    var title: String {
        switch self {
        case .alignLeft: return L10n.text(en: "Align left", zh: "左对齐")
        case .alignCenter: return L10n.text(en: "Align horizontal centers", zh: "水平居中对齐")
        case .alignRight: return L10n.text(en: "Align right", zh: "右对齐")
        case .alignTop: return L10n.text(en: "Align top", zh: "顶端对齐")
        case .alignMiddle: return L10n.text(en: "Align vertical centers", zh: "垂直居中对齐")
        case .alignBottom: return L10n.text(en: "Align bottom", zh: "底端对齐")
        case .horizontal: return L10n.text(en: "Arrange horizontally", zh: "横向排列")
        case .vertical: return L10n.text(en: "Arrange vertically", zh: "纵向排列")
        case .distributeHorizontal: return L10n.text(en: "Equal horizontal gaps", zh: "水平等间距")
        case .distributeVertical: return L10n.text(en: "Equal vertical gaps", zh: "垂直等间距")
        }
    }
}

/// Value-only operations let one document snapshot cover mixed image/annotation
/// gestures. A group shares one clamped delta so edge collisions keep spacing.
enum CaptureObjectOperations {
    static func rect(_ id: CaptureObjectID, layers: [CaptureImageLayer], annotations: [CaptureAnnotation]) -> CGRect? {
        switch id {
        case .image(let id): return layers.first { $0.id == id }?.normalizedRect
        case .annotation(let id): return annotations.first { $0.id == id }?.normalizedBounds
        }
    }

    static func translated(layers: [CaptureImageLayer], annotations: [CaptureAnnotation], selection: Set<CaptureObjectID>,
                           dx: CGFloat, dy: CGFloat) -> (layers: [CaptureImageLayer], annotations: [CaptureAnnotation]) {
        let rects = selection.compactMap { rect($0, layers: layers, annotations: annotations) }
        guard let first = rects.first else { return (layers, annotations) }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        let x = min(max(dx, -bounds.minX), 1 - bounds.maxX)
        let y = min(max(dy, -bounds.minY), 1 - bounds.maxY)
        return translatedUnclamped(layers: layers, annotations: annotations, selection: selection, dx: x, dy: y)
    }

    private static func translatedUnclamped(layers: [CaptureImageLayer], annotations: [CaptureAnnotation],
                                            selection: Set<CaptureObjectID>, dx: CGFloat, dy: CGFloat)
        -> (layers: [CaptureImageLayer], annotations: [CaptureAnnotation]) {
        let images = layers.map { layer -> CaptureImageLayer in
            guard selection.contains(.image(layer.id)) else { return layer }
            var result = layer
            result.normalizedRect = layer.normalizedRect.offsetBy(dx: dx, dy: dy)
            return result
        }
        let objects = annotations.map { selection.contains(.annotation($0.id)) ? $0.translatedBy(dx: dx, dy: dy) : $0 }
        return (images, objects)
    }

    static func deleted(layers: [CaptureImageLayer], annotations: [CaptureAnnotation], selection: Set<CaptureObjectID>)
        -> (layers: [CaptureImageLayer], annotations: [CaptureAnnotation]) {
        (layers.filter { !selection.contains(.image($0.id)) }, annotations.filter { !selection.contains(.annotation($0.id)) })
    }

    static func duplicated(layers: [CaptureImageLayer], annotations: [CaptureAnnotation], selection: Set<CaptureObjectID>) throws
        -> (layers: [CaptureImageLayer], annotations: [CaptureAnnotation], selection: Set<CaptureObjectID>) {
        // Copies retain the visible stacking of the selected group even when
        // the stored array order differs from its z indices.
        var copies = CaptureLayerComposition.ordered(layers).filter { selection.contains(.image($0.id)) }
        var annotationCopies = annotations.filter { selection.contains(.annotation($0.id)) }
        let z = CaptureLayerComposition.ordered(layers).count
        for i in copies.indices { copies[i].id = UUID(); copies[i].zIndex = z + i }
        for i in annotationCopies.indices { annotationCopies[i].id = UUID() }
        let newSelection = Set(copies.map { CaptureObjectID.image($0.id) } + annotationCopies.map { .annotation($0.id) })
        let moved = translated(layers: copies, annotations: annotationCopies, selection: newSelection, dx: 0.025, dy: 0.025)
        let normalized = CaptureLayerComposition.ordered(layers).enumerated().map { offset, layer -> CaptureImageLayer in
            var layer = layer; layer.zIndex = offset; return layer
        }
        try CaptureLayerImport.validate(normalized + moved.layers)
        return (normalized + moved.layers, annotations + moved.annotations, newSelection)
    }

    static func reorder(_ layers: [CaptureImageLayer], selection: Set<CaptureObjectID>, bringForward: Bool) -> [CaptureImageLayer] {
        guard layers.contains(where: { selection.contains(.image($0.id)) }) else { return layers }
        var ordered = CaptureLayerComposition.ordered(layers)
        guard ordered.count > 1 else { return ordered }
        if bringForward {
            for i in stride(from: ordered.count - 2, through: 0, by: -1) {
                if selection.contains(.image(ordered[i].id)), !selection.contains(.image(ordered[i + 1].id)) { ordered.swapAt(i, i + 1) }
            }
        } else {
            for i in 1..<ordered.count {
                if selection.contains(.image(ordered[i].id)), !selection.contains(.image(ordered[i - 1].id)) { ordered.swapAt(i, i - 1) }
            }
        }
        return ordered.enumerated().map { i, layer in var copy = layer; copy.zIndex = i; return copy }
    }

    static func arranged(_ arrangement: CaptureObjectArrangement, layers: [CaptureImageLayer], annotations: [CaptureAnnotation],
                         selection: Set<CaptureObjectID>) -> (layers: [CaptureImageLayer], annotations: [CaptureAnnotation]) {
        // Document order, rather than Set iteration, makes equal-coordinate
        // arrangements deterministic across project reopen and undo.
        let ids = layers.map { CaptureObjectID.image($0.id) } + annotations.map { .annotation($0.id) }
        var items = ids.filter { selection.contains($0) }.compactMap { id in rect(id, layers: layers, annotations: annotations).map { (id, $0) } }
        guard items.count > 1 else { return (layers, annotations) }
        let bounds = items.dropFirst().reduce(items[0].1) { $0.union($1.1) }
        var offsets: [CaptureObjectID: CGPoint] = [:]
        switch arrangement {
        case .horizontal, .vertical, .distributeHorizontal, .distributeVertical:
            let horizontal = arrangement == .horizontal || arrangement == .distributeHorizontal
            items = items.enumerated().sorted { a, b in
                let lhs = horizontal ? a.element.1.midX : a.element.1.midY
                let rhs = horizontal ? b.element.1.midX : b.element.1.midY
                return lhs == rhs ? a.offset < b.offset : lhs < rhs
            }.map(\.element)
            let widths = items.reduce(CGFloat(0)) { $0 + (horizontal ? $1.1.width : $1.1.height) }
            let distribute = arrangement == .distributeHorizontal || arrangement == .distributeVertical
            let span = distribute ? (horizontal ? bounds.width : bounds.height) : min(1, widths + 0.02 * CGFloat(items.count - 1))
            let gap = (span - widths) / CGFloat(items.count - 1)
            var cursor = min(horizontal ? bounds.minX : bounds.minY, max(0, 1 - span))
            for (id, rect) in items {
                offsets[id] = horizontal ? CGPoint(x: cursor - rect.minX, y: distribute ? 0 : bounds.midY - rect.midY)
                    : CGPoint(x: distribute ? 0 : bounds.midX - rect.midX, y: cursor - rect.minY)
                cursor += (horizontal ? rect.width : rect.height) + gap
            }
        default:
            for (id, r) in items {
                let dx: CGFloat, dy: CGFloat
                switch arrangement {
                case .alignLeft: dx = bounds.minX - r.minX; dy = 0
                case .alignCenter: dx = bounds.midX - r.midX; dy = 0
                case .alignRight: dx = bounds.maxX - r.maxX; dy = 0
                case .alignTop: dx = 0; dy = bounds.minY - r.minY
                case .alignMiddle: dx = 0; dy = bounds.midY - r.midY
                case .alignBottom: dx = 0; dy = bounds.maxY - r.maxY
                default: dx = 0; dy = 0
                }
                offsets[id] = CGPoint(x: dx, y: dy)
            }
        }
        var result = (layers: layers, annotations: annotations)
        for (id, _) in items {
            guard let delta = offsets[id] else { continue }
            result = translated(layers: result.layers, annotations: result.annotations, selection: [id], dx: delta.x, dy: delta.y)
        }
        return result
    }
}
