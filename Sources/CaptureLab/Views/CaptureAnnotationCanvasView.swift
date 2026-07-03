import AppKit
import SwiftUI

struct CaptureAnnotationCanvasView: NSViewRepresentable {
    let document: CaptureDocument
    @Binding var annotations: [CaptureAnnotation]
    @Binding var selectedTool: CaptureTool

    func makeCoordinator() -> Coordinator {
        Coordinator(annotations: $annotations)
    }

    func makeNSView(context: Context) -> CaptureAnnotationNSCanvasView {
        let view = CaptureAnnotationNSCanvasView()
        view.setDocument(document)
        view.annotations = annotations
        view.selectedTool = selectedTool
        view.onAnnotationsChanged = { [coordinator = context.coordinator] updated in
            coordinator.annotations.wrappedValue = updated
        }
        return view
    }

    func updateNSView(_ nsView: CaptureAnnotationNSCanvasView, context: Context) {
        context.coordinator.annotations = $annotations
        nsView.setDocument(document)
        nsView.annotations = annotations
        if nsView.selectedTool != selectedTool {
            nsView.selectedTool = selectedTool
        }
        nsView.onAnnotationsChanged = { [coordinator = context.coordinator] updated in
            coordinator.annotations.wrappedValue = updated
        }
    }

    final class Coordinator {
        var annotations: Binding<[CaptureAnnotation]>

        init(annotations: Binding<[CaptureAnnotation]>) {
            self.annotations = annotations
        }
    }
}

final class CaptureAnnotationNSCanvasView: NSView, NSTextFieldDelegate {
    private(set) var document: CaptureDocument?

    var annotations: [CaptureAnnotation] = [] {
        didSet { needsDisplay = true }
    }

    var selectedTool: CaptureTool = .select {
        didSet {
            commitActiveTextEdit()
            if let selected = selectedAnnotation, !canEdit(selected) {
                selectedAnnotationID = nil
            }
            interaction = nil
            needsDisplay = true
        }
    }

    var onAnnotationsChanged: (([CaptureAnnotation]) -> Void)?

    private var documentSignature: String?
    private var selectedAnnotationID: UUID?
    private var interaction: Interaction?
    private var activeTextField: NSTextField?
    private var editingTextAnnotationID: UUID?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setDocument(_ document: CaptureDocument) {
        let signature = Self.signature(for: document)
        if signature != documentSignature {
            discardActiveTextEdit()
            selectedAnnotationID = nil
            interaction = nil
            documentSignature = signature
        }
        self.document = document
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        guard let document else {
            return
        }

        let imageRect = imageDisplayRect(for: document.image.size)
        document.image.draw(
            in: imageRect,
            from: NSRect(origin: .zero, size: document.image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        NSBezierPath(rect: imageRect).stroke()

        for annotation in annotations where annotation.id != editingTextAnnotationID {
            draw(annotation, imageRect: imageRect, document: document)
        }

        if let draft = draftAnnotation(in: imageRect) {
            draw(draft, imageRect: imageRect, document: document, isDraft: true)
        }

        if let selected = selectedAnnotation,
           selected.id != editingTextAnnotationID,
           canEdit(selected) {
            drawSelection(for: selected, imageRect: imageRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else {
            return
        }

        let point = canvasPoint(for: event)
        if let activeTextField,
           !activeTextField.frame.insetBy(dx: -4, dy: -4).contains(point) {
            commitActiveTextEdit()
        }

        window?.makeFirstResponder(self)

        let imageRect = imageDisplayRect(for: document.image.size)
        guard imageRect.contains(point) else {
            selectedAnnotationID = nil
            interaction = nil
            needsDisplay = true
            return
        }

        if let handle = handleHit(at: point, imageRect: imageRect) {
            interaction = handle.interaction
            needsDisplay = true
            return
        }

        if let annotation = annotationHit(at: point, imageRect: imageRect) {
            selectedAnnotationID = annotation.id
            if annotation.kind == .text, event.clickCount >= 2 {
                beginEditingText(annotationID: annotation.id)
                needsDisplay = true
                return
            }
            interaction = .moving(id: annotation.id, original: annotation, start: point)
            needsDisplay = true
            return
        }

        guard let kind = selectedTool.annotationKind else {
            selectedAnnotationID = nil
            interaction = nil
            needsDisplay = true
            return
        }

        selectedAnnotationID = nil
        switch kind {
        case .brush:
            interaction = .brushing(points: [CaptureGeometry.clamped(point, to: imageRect)])
        case .arrow, .line, .rectangle, .counter, .text, .highlight, .mosaic:
            let clamped = CaptureGeometry.clamped(point, to: imageRect)
            interaction = .creating(kind: kind, start: clamped, current: clamped)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let interaction else {
            return
        }

        let imageRect = imageDisplayRect(for: document.image.size)
        let point = CaptureGeometry.clamped(canvasPoint(for: event), to: imageRect)

        switch interaction {
        case .creating(let kind, let start, _):
            self.interaction = .creating(kind: kind, start: start, current: point)
        case .brushing(var points):
            points.append(point)
            self.interaction = .brushing(points: points)
        case .moving(let id, let original, let start):
            let dx = (point.x - start.x) / max(imageRect.width, 1)
            let dy = (point.y - start.y) / max(imageRect.height, 1)
            replaceAnnotation(original.translatedBy(dx: dx, dy: dy), id: id, notifyChange: false)
        case .resizingRect(let id, let original, let handle, let start):
            let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
            let resized = resizedNormalizedRect(
                from: original.normalizedBounds,
                handle: handle,
                translation: translation,
                in: imageRect
            )
            replaceAnnotation(original.scaledToNormalizedRect(resized), id: id, notifyChange: false)
        case .movingArrowPoint(let id, let original, let pointKind, let start):
            let dx = (point.x - start.x) / max(imageRect.width, 1)
            let dy = (point.y - start.y) / max(imageRect.height, 1)
            let index = pointKind == .start ? 0 : 1
            guard original.normalizedPoints.indices.contains(index) else {
                return
            }
            let originalPoint = original.normalizedPoints[index].cgPoint
            let updatedPoint = CGPoint(x: originalPoint.x + dx, y: originalPoint.y + dy).clampedToUnit()
            replaceAnnotation(original.replacingPoint(at: index, with: updatedPoint), id: id, notifyChange: false)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let document, let interaction else {
            self.interaction = nil
            return
        }

        let imageRect = imageDisplayRect(for: document.image.size)

        switch interaction {
        case .creating(let kind, let start, let current):
            commitCreatedAnnotation(kind: kind, start: start, current: current, imageRect: imageRect)
        case .brushing(let points):
            let normalized = points.map { CaptureGeometry.normalizedPoint(from: $0, in: imageRect) }
            commit(.brush(points: normalized))
        case .moving, .resizingRect, .movingArrowPoint:
            onAnnotationsChanged?(annotations)
        }

        self.interaction = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\u{1B}":
            selectedAnnotationID = nil
            interaction = nil
            needsDisplay = true
        case "\u{7F}":
            deleteSelectedAnnotation()
        default:
            super.keyDown(with: event)
        }
    }

    private var selectedAnnotation: CaptureAnnotation? {
        guard let selectedAnnotationID else {
            return nil
        }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    private func imageDisplayRect(for imageSize: CGSize) -> CGRect {
        CaptureGeometry.aspectFitRect(
            imageSize: imageSize,
            in: CGSize(width: max(bounds.width - 160, 1), height: max(bounds.height - 120, 1))
        )
        .offsetBy(dx: 80, dy: 60)
    }

    private func canEdit(_ annotation: CaptureAnnotation) -> Bool {
        selectedTool == .select || selectedTool.annotationKind == annotation.kind
    }

    private func commitCreatedAnnotation(
        kind: CaptureAnnotation.Kind,
        start: CGPoint,
        current: CGPoint,
        imageRect: CGRect
    ) {
        if kind == .arrow || kind == .line {
            guard hypot(current.x - start.x, current.y - start.y) >= 8 else {
                return
            }
            let normalizedStart = CaptureGeometry.normalizedPoint(from: start, in: imageRect)
            let normalizedEnd = CaptureGeometry.normalizedPoint(from: current, in: imageRect)
            commit(kind == .arrow
                ? .arrow(start: normalizedStart, end: normalizedEnd)
                : .line(start: normalizedStart, end: normalizedEnd)
            )
            return
        }

        let displayRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        switch kind {
        case .rectangle, .highlight, .mosaic:
            let normalized = CaptureGeometry.normalizedRect(from: displayRect, in: imageRect)
            commit(CaptureAnnotation(kind: kind, normalizedRect: normalized))
        case .counter:
            let counterRect = counterDisplayRect(start: start, current: current, imageRect: imageRect)
            let normalized = CaptureGeometry.normalizedRect(from: counterRect, in: imageRect)
            commit(CaptureAnnotation(kind: .counter, normalizedRect: normalized, text: nextCounterText()))
        case .text:
            let textRect = textDisplayRect(start: start, current: current, imageRect: imageRect)
            let normalized = CaptureGeometry.normalizedRect(from: textRect, in: imageRect)
            let annotation = CaptureAnnotation.text(normalizedRect: normalized)
            if commit(annotation) {
                beginEditingText(annotationID: annotation.id)
            }
        case .arrow, .line, .brush:
            return
        }
    }

    @discardableResult
    private func commit(_ annotation: CaptureAnnotation) -> Bool {
        let rectThreshold: CGFloat = annotation.kind == .text ? 0.001 : 0.006
        let hasRect = annotation.normalizedRect.width > rectThreshold && annotation.normalizedRect.height > rectThreshold
        let hasLine = annotation.normalizedPoints.count >= 2
        guard hasRect || hasLine else {
            return false
        }
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
        onAnnotationsChanged?(annotations)
        return true
    }

    private func replaceAnnotation(_ annotation: CaptureAnnotation, id: UUID, notifyChange: Bool = true) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            return
        }
        annotations[index] = annotation
        selectedAnnotationID = id
        if notifyChange {
            onAnnotationsChanged?(annotations)
        }
    }

    private func deleteSelectedAnnotation() {
        guard let selectedAnnotationID,
              annotations.contains(where: { $0.id == selectedAnnotationID })
        else {
            return
        }

        annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
        onAnnotationsChanged?(annotations)
        needsDisplay = true
    }

    private func draftAnnotation(in imageRect: CGRect) -> CaptureAnnotation? {
        guard let interaction else {
            return nil
        }

        switch interaction {
        case .creating(let kind, let start, let current):
            if kind == .arrow || kind == .line {
                let normalizedStart = CaptureGeometry.normalizedPoint(from: start, in: imageRect)
                let normalizedEnd = CaptureGeometry.normalizedPoint(from: current, in: imageRect)
                return kind == .arrow
                    ? .arrow(start: normalizedStart, end: normalizedEnd)
                    : .line(start: normalizedStart, end: normalizedEnd)
            }
            let displayRect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            let normalized = CaptureGeometry.normalizedRect(from: displayRect, in: imageRect)
            if kind == .text {
                return .text(normalizedRect: CaptureGeometry.normalizedRect(
                    from: textDisplayRect(start: start, current: current, imageRect: imageRect),
                    in: imageRect
                ))
            }
            if kind == .counter {
                return CaptureAnnotation(
                    kind: .counter,
                    normalizedRect: CaptureGeometry.normalizedRect(
                        from: counterDisplayRect(start: start, current: current, imageRect: imageRect),
                        in: imageRect
                    ),
                    text: nextCounterText()
                )
            }
            return CaptureAnnotation(kind: kind, normalizedRect: normalized)
        case .brushing(let points):
            let normalized = points.map { CaptureGeometry.normalizedPoint(from: $0, in: imageRect) }
            return .brush(points: normalized)
        case .moving, .resizingRect, .movingArrowPoint:
            return nil
        }
    }

    private func annotationHit(at point: CGPoint, imageRect: CGRect) -> CaptureAnnotation? {
        annotations.reversed().first { annotation in
            guard canEdit(annotation) else {
                return false
            }
            switch annotation.kind {
            case .arrow, .line:
                let points = annotation.points(in: imageRect)
                guard points.count >= 2 else { return false }
                return distance(from: point, toSegmentFrom: points[0], to: points[1]) <= 10
            case .brush:
                let points = annotation.points(in: imageRect)
                return zip(points, points.dropFirst()).contains { start, end in
                    distance(from: point, toSegmentFrom: start, to: end) <= 10
                }
            case .rectangle, .counter, .text, .highlight, .mosaic:
                return annotation.rect(in: imageRect).insetBy(dx: -8, dy: -8).contains(point)
            }
        }
    }

    private func handleHit(at point: CGPoint, imageRect: CGRect) -> HandleHit? {
        guard let selected = selectedAnnotation, canEdit(selected) else {
            return nil
        }

        switch selected.kind {
        case .arrow, .line:
            let points = selected.points(in: imageRect)
            guard points.count >= 2 else {
                return nil
            }
            for arrowPoint in ArrowControlPoint.allCases {
                let displayPoint = arrowPoint == .start ? points[0] : points[1]
                if handleRect(center: displayPoint, size: 18).contains(point) {
                    return HandleHit(interaction: .movingArrowPoint(
                        id: selected.id,
                        original: selected,
                        point: arrowPoint,
                        start: point
                    ))
                }
            }
        case .rectangle, .counter, .text, .highlight, .mosaic, .brush:
            let rect = selected.rect(in: imageRect).expandedToMinimumSize(width: 18, height: 18)
            for handle in ResizeHandle.allCases {
                if handleRect(center: handle.position(in: rect), size: 18).contains(point) {
                    return HandleHit(interaction: .resizingRect(
                        id: selected.id,
                        original: selected,
                        handle: handle,
                        start: point
                    ))
                }
            }
        }

        return nil
    }

    private func draw(
        _ annotation: CaptureAnnotation,
        imageRect: CGRect,
        document: CaptureDocument,
        isDraft: Bool = false
    ) {
        let alpha: CGFloat = isDraft ? 0.68 : 1
        switch annotation.kind {
        case .arrow:
            drawArrow(points: annotation.points(in: imageRect), alpha: alpha)
        case .line:
            drawLine(points: annotation.points(in: imageRect), alpha: alpha)
        case .brush:
            drawBrush(points: annotation.points(in: imageRect), alpha: alpha)
        case .rectangle:
            let rect = annotation.rect(in: imageRect)
            NSColor.systemRed.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 3
            path.stroke()
        case .counter:
            drawCounter(annotation, imageRect: imageRect, alpha: alpha)
        case .text:
            drawText(annotation, imageRect: imageRect, alpha: alpha)
        case .highlight:
            drawHighlight(annotation, imageRect: imageRect, alpha: alpha)
        case .mosaic:
            let rect = annotation.rect(in: imageRect)
            drawPixelatedRegion(annotation: annotation, rect: rect, document: document, alpha: alpha)
        }
    }

    private func drawText(_ annotation: CaptureAnnotation, imageRect: CGRect, alpha: CGFloat) {
        let rect = annotation.rect(in: imageRect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize = max(13, min(32, rect.height * 0.42))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.systemRed.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ]
        let text = annotation.text.isEmpty ? "Text" : annotation.text
        let textRect = rect.insetBy(dx: 2, dy: max(0, (rect.height - fontSize * 1.25) / 2))
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawCounter(_ annotation: CaptureAnnotation, imageRect: CGRect, alpha: CGFloat) {
        let rect = annotation.rect(in: imageRect).expandedToMinimumSize(width: 24, height: 24)
        let diameter = min(rect.width, rect.height)
        let circleRect = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        NSColor.systemRed.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let value = annotation.text.isEmpty ? "1" : annotation.text
        let fontSize = max(12, diameter * 0.48)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ]
        let textHeight = fontSize * 1.18
        let textRect = CGRect(
            x: circleRect.minX,
            y: circleRect.midY - textHeight / 2,
            width: circleRect.width,
            height: textHeight
        )
        (value as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawHighlight(_ annotation: CaptureAnnotation, imageRect: CGRect, alpha: CGFloat) {
        let rect = annotation.rect(in: imageRect)
        NSColor.systemYellow.withAlphaComponent(0.42 * alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private func beginEditingText(annotationID: UUID) {
        guard let document,
              let annotation = annotations.first(where: { $0.id == annotationID }),
              annotation.kind == .text
        else {
            return
        }

        discardActiveTextEdit()

        let imageRect = imageDisplayRect(for: document.image.size)
        let rect = annotation.rect(in: imageRect).expandedToMinimumSize(width: 120, height: 34)
        let field = NSTextField(frame: rect)
        field.stringValue = annotation.text.isEmpty ? "Text" : annotation.text
        field.font = NSFont.systemFont(ofSize: max(13, min(32, rect.height * 0.42)), weight: .semibold)
        field.textColor = .systemRed
        field.alignment = .center
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail

        activeTextField = field
        editingTextAnnotationID = annotationID
        selectedAnnotationID = annotationID
        addSubview(field)

        if let window {
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        needsDisplay = true
    }

    private func commitActiveTextEdit() {
        guard let field = activeTextField,
              let id = editingTextAnnotationID
        else {
            return
        }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        activeTextField = nil
        editingTextAnnotationID = nil

        if text.isEmpty {
            annotations.removeAll { $0.id == id }
            selectedAnnotationID = nil
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].text = text
            selectedAnnotationID = id
        }

        onAnnotationsChanged?(annotations)
        needsDisplay = true
    }

    private func discardActiveTextEdit() {
        activeTextField?.delegate = nil
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        editingTextAnnotationID = nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveTextEdit()
    }

    private func drawArrow(points: [CGPoint], alpha: CGFloat) {
        guard points.count >= 2 else {
            return
        }
        let start = points[0]
        let end = points[1]
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 3
        path.move(to: start)
        path.line(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 14
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        path.move(to: left)
        path.line(to: end)
        path.line(to: right)

        NSColor.systemRed.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawLine(points: [CGPoint], alpha: CGFloat) {
        guard points.count >= 2 else {
            return
        }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 3
        path.move(to: points[0])
        path.line(to: points[1])

        NSColor.systemRed.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawBrush(points: [CGPoint], alpha: CGFloat) {
        guard let first = points.first, points.count >= 2 else {
            return
        }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 4
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        NSColor.systemRed.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawPixelatedRegion(
        annotation: CaptureAnnotation,
        rect: CGRect,
        document: CaptureDocument,
        alpha: CGFloat
    ) {
        guard let pixelated = pixelatedImage(for: annotation, document: document) else {
            NSColor.black.withAlphaComponent(0.3 * alpha).setFill()
            NSBezierPath(rect: rect).fill()
            return
        }
        pixelated.draw(
            in: rect,
            from: NSRect(origin: .zero, size: pixelated.size),
            operation: .sourceOver,
            fraction: alpha,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawSelection(for annotation: CaptureAnnotation, imageRect: CGRect) {
        switch annotation.kind {
        case .arrow, .line:
            let points = annotation.points(in: imageRect)
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.move(to: points[0])
            path.line(to: points[1])
            NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
            path.stroke()
            drawHandle(center: points[0])
            drawHandle(center: points[1])
        case .rectangle, .counter, .text, .highlight, .mosaic, .brush:
            let rect = annotation.rect(in: imageRect).expandedToMinimumSize(width: 18, height: 18)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.2
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            for handle in ResizeHandle.allCases {
                drawHandle(center: handle.position(in: rect))
            }
        }
    }

    private func drawHandle(center: CGPoint) {
        let rect = handleRect(center: center, size: 8)
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.4
        path.stroke()
    }

    private func pixelatedImage(for annotation: CaptureAnnotation, document: CaptureDocument) -> NSImage? {
        guard annotation.normalizedRect.width > 0,
              annotation.normalizedRect.height > 0,
              let source = document.image.captureLabCGImage()
        else {
            return nil
        }

        let pixelSize = CGSize(width: source.width, height: source.height)
        let crop = CGRect(
            x: annotation.normalizedRect.minX * pixelSize.width,
            y: annotation.normalizedRect.minY * pixelSize.height,
            width: annotation.normalizedRect.width * pixelSize.width,
            height: annotation.normalizedRect.height * pixelSize.height
        )
        .integral

        guard let cropped = source.cropping(to: crop) else {
            return nil
        }

        let block = 6
        let tinyWidth = max(1, cropped.width / block)
        let tinyHeight = max(1, cropped.height / block)
        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
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
        smallContext.draw(cropped, in: CGRect(x: 0, y: 0, width: tinyWidth, height: tinyHeight))
        guard let small = smallContext.makeImage() else {
            return nil
        }

        guard let outputContext = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        outputContext.interpolationQuality = .none
        outputContext.draw(small, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let output = outputContext.makeImage() else {
            return nil
        }

        return NSImage(cgImage: output, size: annotation.rect(in: imageDisplayRect(for: document.image.size)).size)
    }

    private func resizedNormalizedRect(
        from rect: CGRect,
        handle: ResizeHandle,
        translation: CGSize,
        in imageRect: CGRect
    ) -> CGRect {
        let dx = translation.width / max(imageRect.width, 1)
        let dy = translation.height / max(imageRect.height, 1)
        let minWidth = max(8 / max(imageRect.width, 1), 0.006)
        let minHeight = max(8 / max(imageRect.height, 1), 0.006)

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle.horizontal {
        case .west:
            minX = min(max(minX + dx, 0), maxX - minWidth)
        case .east:
            maxX = max(min(maxX + dx, 1), minX + minWidth)
        case .center:
            break
        }

        switch handle.vertical {
        case .north:
            minY = min(max(minY + dy, 0), maxY - minHeight)
        case .south:
            maxY = max(min(maxY + dy, 1), minY + minHeight)
        case .middle:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).clampedToUnit()
    }

    private func textDisplayRect(start: CGPoint, current: CGPoint, imageRect: CGRect) -> CGRect {
        let draggedWidth = abs(current.x - start.x)
        let draggedHeight = abs(current.y - start.y)
        let isClick = draggedWidth < 6 && draggedHeight < 6
        let defaultSize = CGSize(
            width: min(180, imageRect.width * 0.42),
            height: min(52, imageRect.height * 0.18)
        )
        let size = isClick
            ? defaultSize
            : CGSize(width: max(draggedWidth, 80), height: max(draggedHeight, 32))
        let origin = isClick
            ? CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2)
            : CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))

        var rect = CGRect(origin: origin, size: size)
        if rect.minX < imageRect.minX {
            rect.origin.x = imageRect.minX
        }
        if rect.minY < imageRect.minY {
            rect.origin.y = imageRect.minY
        }
        if rect.maxX > imageRect.maxX {
            rect.origin.x = imageRect.maxX - rect.width
        }
        if rect.maxY > imageRect.maxY {
            rect.origin.y = imageRect.maxY - rect.height
        }
        return rect.intersection(imageRect)
    }

    private func counterDisplayRect(start: CGPoint, current: CGPoint, imageRect: CGRect) -> CGRect {
        let draggedWidth = abs(current.x - start.x)
        let draggedHeight = abs(current.y - start.y)
        let isClick = draggedWidth < 6 && draggedHeight < 6
        let side = isClick ? CGFloat(32) : max(28, max(draggedWidth, draggedHeight))
        let origin = isClick
            ? CGPoint(x: start.x - side / 2, y: start.y - side / 2)
            : CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))

        var rect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        if rect.minX < imageRect.minX {
            rect.origin.x = imageRect.minX
        }
        if rect.minY < imageRect.minY {
            rect.origin.y = imageRect.minY
        }
        if rect.maxX > imageRect.maxX {
            rect.origin.x = imageRect.maxX - rect.width
        }
        if rect.maxY > imageRect.maxY {
            rect.origin.y = imageRect.maxY - rect.height
        }
        return rect.intersection(imageRect)
    }

    private func nextCounterText() -> String {
        let highestCounter = annotations
            .filter { $0.kind == .counter }
            .compactMap { Int($0.text) }
            .max() ?? 0
        return "\(highestCounter + 1)"
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if dx == 0 && dy == 0 {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func handleRect(center: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    private func canvasPoint(for event: NSEvent) -> CGPoint {
        guard window != nil else {
            return event.locationInWindow
        }
        return convert(event.locationInWindow, from: nil)
    }

    private static func signature(for document: CaptureDocument) -> String {
        let pixelSize = document.pixelSize
        return [
            document.sourceURL?.path ?? "capture",
            "\(document.createdAt.timeIntervalSinceReferenceDate)",
            "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        ].joined(separator: "|")
    }
}

private struct HandleHit {
    let interaction: Interaction
}

private enum Interaction {
    case creating(kind: CaptureAnnotation.Kind, start: CGPoint, current: CGPoint)
    case brushing(points: [CGPoint])
    case moving(id: UUID, original: CaptureAnnotation, start: CGPoint)
    case resizingRect(id: UUID, original: CaptureAnnotation, handle: ResizeHandle, start: CGPoint)
    case movingArrowPoint(id: UUID, original: CaptureAnnotation, point: ArrowControlPoint, start: CGPoint)
}

private enum ResizeHandle: String, CaseIterable, Identifiable, Equatable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    enum Horizontal {
        case west
        case center
        case east
    }

    enum Vertical {
        case north
        case middle
        case south
    }

    var id: String { rawValue }

    var horizontal: Horizontal {
        switch self {
        case .topLeft, .left, .bottomLeft:
            return .west
        case .top, .bottom:
            return .center
        case .topRight, .right, .bottomRight:
            return .east
        }
    }

    var vertical: Vertical {
        switch self {
        case .topLeft, .top, .topRight:
            return .north
        case .left, .right:
            return .middle
        case .bottomLeft, .bottom, .bottomRight:
            return .south
        }
    }

    func position(in rect: CGRect) -> CGPoint {
        let x: CGFloat
        switch horizontal {
        case .west:
            x = rect.minX
        case .center:
            x = rect.midX
        case .east:
            x = rect.maxX
        }

        let y: CGFloat
        switch vertical {
        case .north:
            y = rect.minY
        case .middle:
            y = rect.midY
        case .south:
            y = rect.maxY
        }

        return CGPoint(x: x, y: y)
    }
}

private enum ArrowControlPoint: String, CaseIterable, Identifiable, Equatable {
    case start
    case end

    var id: String { rawValue }
}

private extension CGRect {
    func expandedToMinimumSize(width minimumWidth: CGFloat, height minimumHeight: CGFloat) -> CGRect {
        var rect = self
        if rect.width < minimumWidth {
            rect.origin.x -= (minimumWidth - rect.width) / 2
            rect.size.width = minimumWidth
        }
        if rect.height < minimumHeight {
            rect.origin.y -= (minimumHeight - rect.height) / 2
            rect.size.height = minimumHeight
        }
        return rect
    }
}
