import AppKit
import SwiftUI

struct CaptureAnnotationCanvasView: NSViewRepresentable {
    let document: CaptureDocument
    @Binding var annotations: [CaptureAnnotation]
    @Binding var selectedTool: CaptureTool
    @Binding var zoomLevel: CaptureZoomLevel
    var editingSession: CaptureEditingSession = .shared
    var highlightTextRegions: [CGRect] = []
    var annotationAppearance: CaptureAnnotationAppearance = .editorDefault
    var selectedAnnotationID: UUID?
    var cropSelection: Binding<CGRect?> = .constant(nil)
    var onSelectionChanged: (UUID?) -> Void = { _ in }
    var cropPreset: CaptureCropPreset = .free
    var applyCrop: () -> Void = {}
    var cancelCrop: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(annotations: $annotations)
    }

    func makeNSView(context: Context) -> CaptureAnnotationNSCanvasView {
        let view = CaptureAnnotationNSCanvasView()
        view.setDocument(document)
        view.annotations = annotations
        view.selectedTool = selectedTool
        view.zoomLevel = zoomLevel
        view.setEditingSession(editingSession)
        configureInteractions(view)
        view.onAnnotationsChanged = { [coordinator = context.coordinator] updated in
            coordinator.lastAnnotationsFromModel = updated
            coordinator.annotations.wrappedValue = updated
        }
        return view
    }

    func updateNSView(_ nsView: CaptureAnnotationNSCanvasView, context: Context) {
        context.coordinator.annotations = $annotations
        nsView.withModelSelectionSynchronization {
            nsView.setDocument(document)
            let annotationsChangedExternally = context.coordinator.lastAnnotationsFromModel != annotations
            if annotationsChangedExternally {
                nsView.cancelPointerInteraction()
            }
            // Selection changes schedule a SwiftUI update before the pointer edit
            // is committed to the binding at mouseUp. Preserve that native preview
            // until the gesture ends. Actual model edits (undo/delete), as well as
            // document/tool/zoom changes, still cancel the gesture and synchronize.
            if !nsView.hasActivePointerInteraction || nsView.selectedTool != selectedTool || nsView.zoomLevel != zoomLevel {
                nsView.annotations = annotations
            }
            context.coordinator.lastAnnotationsFromModel = annotations
            nsView.zoomLevel = zoomLevel
            nsView.setEditingSession(editingSession)
            if nsView.selectedTool != selectedTool {
                nsView.selectedTool = selectedTool
            }
            // Apply the model's selection after properties that can clear it.
            configureInteractions(nsView)
            nsView.onAnnotationsChanged = { [coordinator = context.coordinator] updated in
                coordinator.lastAnnotationsFromModel = updated
                coordinator.annotations.wrappedValue = updated
            }
        }
    }

    private func configureInteractions(_ view: CaptureAnnotationNSCanvasView) {
        view.annotationAppearance = annotationAppearance
        view.highlightTextRegions = highlightTextRegions
        view.synchronizeSelection(selectedAnnotationID)
        view.cropSelection = cropSelection.wrappedValue
        view.cropPreset = cropPreset
        view.onSelectionChanged = onSelectionChanged
        view.onCropSelectionChanged = { selection in cropSelection.wrappedValue = selection }
        view.onApplyCrop = applyCrop
        view.onCancelCrop = cancelCrop
    }

    static func dismantleNSView(
        _ nsView: CaptureAnnotationNSCanvasView,
        coordinator: Coordinator
    ) {
        // Switching between fit and fixed zoom changes the SwiftUI hierarchy
        // around this representable. Flush the field editor before SwiftUI tears
        // down the old AppKit view, then release its shared-session callback.
        nsView.prepareForDismantle()
    }

    final class Coordinator {
        var annotations: Binding<[CaptureAnnotation]>
        var lastAnnotationsFromModel: [CaptureAnnotation]

        init(annotations: Binding<[CaptureAnnotation]>) {
            self.annotations = annotations
            lastAnnotationsFromModel = annotations.wrappedValue
        }
    }
}

final class CaptureAnnotationNSCanvasView: NSView, NSTextFieldDelegate {
    private(set) var document: CaptureDocument?

    var annotations: [CaptureAnnotation] = [] {
        didSet {
            pruneMosaicCache()
            if let id = selectedAnnotationID, !annotations.contains(where: { $0.id == id }) {
                selectedAnnotationID = nil
            }
            needsDisplay = true
        }
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

    var zoomLevel: CaptureZoomLevel = .fit {
        didSet {
            if oldValue != zoomLevel {
                commitActiveTextEdit()
                interaction = nil
                needsDisplay = true
            }
        }
    }

    var onAnnotationsChanged: (([CaptureAnnotation]) -> Void)?

    private var transformedPreview: (id: UUID, annotations: [CaptureAnnotation], image: NSImage?)?
    private var documentSignature: String?
    private var selectedAnnotationID: UUID? {
        didSet {
            if !isSynchronizingSelection, oldValue != selectedAnnotationID { onSelectionChanged?(selectedAnnotationID) }
        }
    }
    var highlightTextRegions: [CGRect] = []
    var annotationAppearance: CaptureAnnotationAppearance = .editorDefault
    var cropSelection: CGRect? { didSet { needsDisplay = true } }
    var cropPreset: CaptureCropPreset = .free
    var onSelectionChanged: ((UUID?) -> Void)?
    var onCropSelectionChanged: ((CGRect?) -> Void)?
    var onApplyCrop: (() -> Void)?
    var onCancelCrop: (() -> Void)?
    private var isSynchronizingSelection = false
    private var interaction: Interaction?
    private var activeTextField: NSTextField?
    private var editingTextAnnotationID: UUID?
    private var editingSession: CaptureEditingSession?
    private var mosaicCache: [UUID: MosaicCacheEntry] = [:]
    private var mosaicCachePixelCost = 0

    private let maximumMosaicCacheEntries = 32
    private let maximumMosaicCachePixelCost = 16_000_000
    private let maximumMosaicPreviewPixelCost = 4_000_000

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var hasActivePointerInteraction: Bool { interaction != nil }

    func cancelPointerInteraction() {
        interaction = nil
        needsDisplay = true
    }

    func synchronizeSelection(_ id: UUID?) {
        let resolved = id.flatMap { candidate in annotations.contains(where: { $0.id == candidate }) ? candidate : nil }
        guard selectedAnnotationID != resolved else { return }
        withModelSelectionSynchronization {
            selectedAnnotationID = resolved
        }
        needsDisplay = true
    }

    func withModelSelectionSynchronization(_ update: () -> Void) {
        // Model-to-view synchronization must not feed selection changes back
        // through a SwiftUI publisher. Keep native pointer callbacks enabled
        // outside this scope, and preserve an enclosing synchronization scope.
        let wasSynchronizingSelection = isSynchronizingSelection
        isSynchronizingSelection = true
        defer { isSynchronizingSelection = wasSynchronizingSelection }
        update()
    }

    func setEditingSession(_ session: CaptureEditingSession) {
        guard editingSession !== session else {
            return
        }
        editingSession?.unregisterPendingTextCommitter(owner: self)
        editingSession = session
        session.registerPendingTextCommitter(owner: self) { [weak self] in
            self?.commitActiveTextEdit()
        }
    }

    func prepareForDismantle() {
        commitActiveTextEdit()
        editingSession?.unregisterPendingTextCommitter(owner: self)
        editingSession = nil
        onAnnotationsChanged = nil
        onSelectionChanged = nil
        onCropSelectionChanged = nil
        onApplyCrop = nil
        onCancelCrop = nil
    }

    func setDocument(_ document: CaptureDocument) {
        let signature = Self.signature(for: document)
        if signature != documentSignature {
            discardActiveTextEdit()
            selectedAnnotationID = nil
            interaction = nil
            clearMosaicCache()
            transformedPreview = nil
            documentSignature = signature
        }
        self.document = document
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit can pass dirty regions outside an unclipped view on newer
        // macOS versions. Keep the native canvas from painting over toolbars.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()

        guard let document else {
            return
        }

        let imageRect = imageDisplayRect(for: document.image.size)
        let usesGeometry = document.geometry != CaptureDocumentGeometry()
            || annotations.contains { $0.kind == .blur || $0.kind == .mosaic }
        let visibleAnnotations = annotations.filter { $0.id != editingTextAnnotationID }
        if usesGeometry {
            if transformedPreview?.id != document.id || transformedPreview?.annotations != visibleAnnotations {
                let composed = document.image.renderedWithCaptureLabAnnotations(visibleAnnotations)
                transformedPreview = (document.id, visibleAnnotations, composed.flatMap { document.applyingGeometry(to: $0) })
            }
            // An unsuccessful composition leaves an empty canvas, never a source fallback.
            transformedPreview?.image?.draw(in: outputDisplayRect, from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: outputDisplayRect).addClip()
        NSGraphicsContext.current?.cgContext.concatenate(sourceViewTransform)
        if !usesGeometry {
            document.image.draw(in: imageRect, from: NSRect(origin: .zero, size: document.image.size),
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
            NSBezierPath(rect: imageRect).stroke()
            for annotation in visibleAnnotations { draw(annotation, imageRect: imageRect, document: document) }
        }

        if let draft = draftAnnotation(in: imageRect) {
            var styledDraft = draft
            styledDraft.appearance = annotationAppearance
            if styledDraft.kind == .highlight, annotationAppearance.highlightTextAlignment == true {
                styledDraft = styledDraft.withNormalizedRect(CaptureHighlightAlignment.alignedRect(styledDraft.normalizedRect, textRegions: highlightTextRegions))
            }
            styledDraft = styledDraft.fittingFontBounds(in: document.sourcePixelSize)
            draw(styledDraft, imageRect: imageRect, document: document, isDraft: true)
        }


        if let selected = selectedAnnotation,
           selected.id != editingTextAnnotationID,
           canEdit(selected) {
            drawSelection(for: selected, imageRect: imageRect)
        }
        NSGraphicsContext.restoreGraphicsState()
        if selectedTool == .crop { drawCropSelection(in: outputDisplayRect) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else {
            return
        }

        let point = canvasPoint(for: event)
        if let activeTextField,
           !activeTextField.frame.insetBy(dx: -4, dy: -4).contains(rawCanvasPoint(for: event)) {
            commitActiveTextEdit()
        }

        window?.makeFirstResponder(self)

        let imageRect = selectedTool == .crop ? outputDisplayRect : imageDisplayRect(for: document.image.size)
        guard outputDisplayRect.contains(rawCanvasPoint(for: event)), imageRect.contains(point) else {
            selectedAnnotationID = nil
            interaction = nil
            needsDisplay = true
            return
        }

        if selectedTool == .crop {
            selectedAnnotationID = nil
            if let cropSelection {
                let rect = cropRectInView(cropSelection)
                if let corner = [ResizeHandle.topLeft, .topRight, .bottomLeft, .bottomRight].first(where: {
                    handleRect(center: $0.position(in: rect), size: 16).contains(point)
                }) {
                    interaction = .adjustingCrop(original: cropSelection, handle: corner, start: point)
                } else if rect.contains(point) {
                    interaction = .adjustingCrop(original: cropSelection, handle: nil, start: point)
                } else {
                    interaction = .cropping(start: point, current: point)
                }
            } else { interaction = .cropping(start: point, current: point) }
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
        case .arrow, .curvedArrow, .line, .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic:
            let clamped = CaptureGeometry.clamped(point, to: imageRect)
            interaction = .creating(kind: kind, start: clamped, current: clamped)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let interaction else {
            return
        }

        let imageRect = selectedTool == .crop ? outputDisplayRect : imageDisplayRect(for: document.image.size)
        let point = CaptureGeometry.clamped(canvasPoint(for: event), to: imageRect)

        switch interaction {
        case .cropping(let start, _):
            self.interaction = .cropping(start: start, current: point)
            updateCropSelection(start: start, current: point, imageRect: imageRect)
        case .adjustingCrop(let original, let handle, let start):
            if let handle {
                let rect = cropRectInView(original)
                let opposite = CGPoint(x: handle.horizontal == .west ? rect.maxX : rect.minX,
                                       y: handle.vertical == .north ? rect.maxY : rect.minY)
                updateCropSelection(start: opposite, current: point, imageRect: imageRect)
            } else {
                cropSelection = CaptureCropGeometry.moving(original,
                    dx: (point.x - start.x) / imageRect.width, dy: (point.y - start.y) / imageRect.height,
                    snap: CGSize(width: 8 / imageRect.width, height: 8 / imageRect.height), pixelSize: document.canvasSize)
                onCropSelectionChanged?(cropSelection)
            }
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
            let index = pointKind.index
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

        let imageRect = selectedTool == .crop ? outputDisplayRect : imageDisplayRect(for: document.image.size)

        switch interaction {
        case .cropping(let start, let current):
            updateCropSelection(start: start, current: current, imageRect: imageRect)
        case .adjustingCrop: break
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
        if selectedTool == .crop {
            if event.charactersIgnoringModifiers == "\u{1B}" {
                cropSelection = nil
                onCropSelectionChanged?(nil)
                interaction = nil
                onCancelCrop?()
                needsDisplay = true
                return
            }
            if event.charactersIgnoringModifiers == "\r" {
                interaction = nil
                onApplyCrop?()
                return
            }
        }
        switch event.charactersIgnoringModifiers {
        case "\u{1B}":
            selectedAnnotationID = nil
            interaction = nil
            needsDisplay = true
        case "\u{7F}":
            deleteSelectedAnnotation()
        case "\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}":
            guard let selected = selectedAnnotation, let document else { super.keyDown(with: event); return }
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let key = event.charactersIgnoringModifiers
            let viewDelta = CGPoint(x: key == "\u{F702}" ? -amount : key == "\u{F703}" ? amount : 0,
                                    y: key == "\u{F700}" ? -amount : key == "\u{F701}" ? amount : 0)
            let inverse = document.geometry.transform.inverted()
            let delta = viewDelta.applying(CGAffineTransform(a: inverse.a, b: inverse.b, c: inverse.c, d: inverse.d, tx: 0, ty: 0))
            replaceAnnotation(selected.translatedBy(dx: delta.x / document.sourcePixelSize.width,
                                                     dy: delta.y / document.sourcePixelSize.height), id: selected.id)
            needsDisplay = true
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

    var outputDisplayRect: CGRect {
        layoutImageRect(for: document?.displaySize ?? .zero)
    }

    private func imageDisplayRect(for imageSize: CGSize) -> CGRect {
        guard let document else { return layoutImageRect(for: imageSize) }
        let output = outputDisplayRect
        return CGRect(origin: output.origin,
                      size: CGSize(width: document.sourcePixelSize.width * output.width / document.canvasSize.width,
                                   height: document.sourcePixelSize.height * output.height / document.canvasSize.height))
    }

    var sourceViewTransform: CGAffineTransform {
        guard let document else { return .identity }
        let output = outputDisplayRect
        let sx = output.width / document.canvasSize.width
        let sy = output.height / document.canvasSize.height
        return CGAffineTransform(translationX: -output.minX, y: -output.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / sx, y: 1 / sy))
            .concatenating(document.geometry.transform)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: output.minX, y: output.minY))
    }

    private func layoutImageRect(for imageSize: CGSize) -> CGRect {
        let contentOrigin = CGPoint(x: 80, y: 60)
        let contentSize = CGSize(width: max(bounds.width - 160, 1), height: max(bounds.height - 120, 1))

        if let scale = zoomLevel.scale {
            let scaledSize = CGSize(
                width: max(imageSize.width * scale, 1),
                height: max(imageSize.height * scale, 1)
            )
            return CGRect(
                x: contentOrigin.x + (contentSize.width - scaledSize.width) / 2,
                y: contentOrigin.y + (contentSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )
        }

        return CaptureGeometry.aspectFitRect(
            imageSize: imageSize,
            in: contentSize
        )
        .offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
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
        if kind == .arrow || kind == .curvedArrow || kind == .line {
            guard hypot(current.x - start.x, current.y - start.y) >= 8 else {
                return
            }
            let normalizedStart = CaptureGeometry.normalizedPoint(from: start, in: imageRect)
            let normalizedEnd = CaptureGeometry.normalizedPoint(from: current, in: imageRect)
            commit(kind == .curvedArrow ? .curvedArrow(start: normalizedStart, end: normalizedEnd) : kind == .arrow
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
        case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .highlight, .mosaic:
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
        case .arrow, .curvedArrow, .line, .brush:
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
        var styled = annotation
        styled.appearance = annotationAppearance
        if styled.kind == .highlight, annotationAppearance.highlightTextAlignment == true {
            styled = styled.withNormalizedRect(CaptureHighlightAlignment.alignedRect(styled.normalizedRect, textRegions: highlightTextRegions))
        }
        if let document { styled = styled.fittingFontBounds(in: document.sourcePixelSize) }
        annotations.append(styled)
        onAnnotationsChanged?(annotations)
        selectedAnnotationID = annotation.id
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
            if kind == .arrow || kind == .curvedArrow || kind == .line {
                let normalizedStart = CaptureGeometry.normalizedPoint(from: start, in: imageRect)
                let normalizedEnd = CaptureGeometry.normalizedPoint(from: current, in: imageRect)
                return kind == .curvedArrow ? .curvedArrow(start: normalizedStart, end: normalizedEnd) : kind == .arrow
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
        case .cropping, .adjustingCrop, .moving, .resizingRect, .movingArrowPoint:
            return nil
        }
    }

    private func updateCropSelection(start: CGPoint, current: CGPoint, imageRect: CGRect) {
        guard let document else { return }
        func snapped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: abs(point.x - imageRect.minX) < 8 ? imageRect.minX : (abs(point.x - imageRect.maxX) < 8 ? imageRect.maxX : point.x),
                    y: abs(point.y - imageRect.minY) < 8 ? imageRect.minY : (abs(point.y - imageRect.maxY) < 8 ? imageRect.maxY : point.y))
        }
        let rect = CaptureCropGeometry.selection(
            anchor: CaptureGeometry.normalizedPoint(from: snapped(start), in: imageRect),
            current: CaptureGeometry.normalizedPoint(from: snapped(current), in: imageRect),
            size: document.canvasSize, ratio: cropPreset.ratio(in: document.canvasSize))
        let selection: CGRect? = rect.width * imageRect.width >= 1 && rect.height * imageRect.height >= 1 ? rect : nil
        cropSelection = selection
        onCropSelectionChanged?(selection)
    }

    private func cropRectInView(_ selection: CGRect) -> CGRect {
        let rect = outputDisplayRect
        return CGRect(x: rect.minX + selection.minX * rect.width, y: rect.minY + selection.minY * rect.height,
                      width: selection.width * rect.width, height: selection.height * rect.height)
    }

    private func drawCropSelection(in imageRect: CGRect) {
        guard let selection = cropSelection else { return }
        let rect = CGRect(x: imageRect.minX + selection.minX * imageRect.width,
                          y: imageRect.minY + selection.minY * imageRect.height,
                          width: selection.width * imageRect.width,
                          height: selection.height * imageRect.height)
        let mask = NSBezierPath(rect: imageRect)
        mask.append(NSBezierPath(rect: rect))
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        mask.fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        outline.stroke()
        for corner in [ResizeHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect(center: corner.position(in: rect), size: 8)).fill()
        }
        for fraction: CGFloat in [1 / 3, 2 / 3] {
            let grid = NSBezierPath()
            grid.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            grid.line(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            grid.line(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            grid.lineWidth = 0.5
            grid.stroke()
        }
    }

    private func annotationHit(at point: CGPoint, imageRect: CGRect) -> CaptureAnnotation? {
        annotations.reversed().first { annotation in
            guard canEdit(annotation) else {
                return false
            }
            switch annotation.kind {
            case .arrow, .curvedArrow, .line:
                let points = annotation.points(in: imageRect)
                guard points.count >= 2 else { return false }
                let line = annotation.kind == .curvedArrow ? CaptureAnnotationPaths.curvePoints(points) : Array(points.prefix(2))
                return zip(line, line.dropFirst()).contains { distance(from: point, toSegmentFrom: $0, to: $1) <= 10 }
            case .brush:
                let points = annotation.points(in: imageRect)
                return zip(points, points.dropFirst()).contains { start, end in
                    distance(from: point, toSegmentFrom: start, to: end) <= 10
                }
            case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic:
                return annotation.rect(in: imageRect).insetBy(dx: -8, dy: -8).contains(point)
            }
        }
    }

    private func handleHit(at point: CGPoint, imageRect: CGRect) -> HandleHit? {
        guard let selected = selectedAnnotation, canEdit(selected) else {
            return nil
        }

        switch selected.kind {
        case .arrow, .curvedArrow, .line:
            let points = selected.points(in: imageRect)
            guard points.count >= 2 else {
                return nil
            }
            for arrowPoint in ArrowControlPoint.allCases {
                guard points.indices.contains(arrowPoint.index) else { continue }
                let displayPoint = points[arrowPoint.index]
                if handleRect(center: displayPoint, size: 18).contains(point) {
                    return HandleHit(interaction: .movingArrowPoint(
                        id: selected.id,
                        original: selected,
                        point: arrowPoint,
                        start: point
                    ))
                }
            }
        case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic, .brush:
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
        let style = annotationStyle(for: document, imageRect: imageRect, appearance: annotation.appearance)
        switch annotation.kind {
        case .arrow, .curvedArrow:
            CaptureAnnotationPaths.drawArrow(points: annotation.points(in: imageRect), curved: annotation.kind == .curvedArrow, style: style, alpha: alpha)
        case .line:
            drawLine(points: annotation.points(in: imageRect), style: style, alpha: alpha)
        case .brush:
            drawBrush(points: annotation.points(in: imageRect), style: style, alpha: alpha)
        case .rectangle, .ellipse, .filledRectangle:
            CaptureAnnotationPaths.drawShape(rect: annotation.rect(in: imageRect), kind: annotation.kind, style: style, alpha: alpha)
        case .spotlight:
            CaptureAnnotationPaths.drawSpotlight(rect: annotation.rect(in: imageRect), imageRect: imageRect, style: style, alpha: alpha)
        case .blur:
            let rect = annotation.rect(in: imageRect)
            if let composed = document.image.renderedWithCaptureLabAnnotations(annotations.filter { $0.id != annotation.id }),
               let source = composed.captureLabCGImage(),
               let blurred = CaptureBlur.image(from: source, normalizedRect: annotation.normalizedRect, radius: annotation.appearance.blurRadius ?? 12) {
                NSImage(cgImage: blurred, size: CGSize(width: blurred.width, height: blurred.height))
                    .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else { NSColor.black.setFill(); NSBezierPath(rect: rect).fill() }
        case .counter:
            drawCounter(annotation, imageRect: imageRect, style: style, alpha: alpha)
        case .text:
            drawText(annotation, imageRect: imageRect, style: style, alpha: alpha)
        case .highlight:
            drawHighlight(annotation, imageRect: imageRect, style: style, alpha: alpha)
        case .mosaic:
            let rect = annotation.rect(in: imageRect)
            if isDraft, !annotations.isEmpty {
                if let composed = document.image.renderedWithCaptureLabAnnotations(annotations),
                   let source = composed.captureLabCGImage(),
                   let pixels = CapturePixelation.pixelatedImage(from: source, normalizedRect: annotation.normalizedRect) {
                    NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
                        .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else { NSColor.black.setFill(); NSBezierPath(rect: rect).fill() }
            } else {
                drawPixelatedRegion(annotation: annotation, rect: rect, document: document, shouldCache: !isDraft)
            }
        }
    }

    private func drawText(
        _ annotation: CaptureAnnotation,
        imageRect: CGRect,
        style: CaptureAnnotationStyle,
        alpha: CGFloat
    ) {
        CaptureAnnotationPaths.drawText(annotation.text.isEmpty ? L10n.defaultAnnotationText : annotation.text,
                                        rect: annotation.rect(in: imageRect), style: style, alpha: alpha)
    }

    private func drawCounter(
        _ annotation: CaptureAnnotation,
        imageRect: CGRect,
        style: CaptureAnnotationStyle,
        alpha: CGFloat
    ) {
        let rect = annotation.rect(in: imageRect)
        let diameter = max(style.minimumCounterDiameter, min(rect.width, rect.height))
        let circleRect = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        style.color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let value = annotation.text.isEmpty ? "1" : annotation.text
        let fontSize = style.counterFontSize(for: diameter, text: value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: style.counterTextColor.withAlphaComponent(alpha),
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

    private func drawHighlight(
        _ annotation: CaptureAnnotation,
        imageRect: CGRect,
        style: CaptureAnnotationStyle,
        alpha: CGFloat
    ) {
        let rect = annotation.rect(in: imageRect)
        style.highlightColor.withAlphaComponent(0.42 * alpha).setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: style.highlightCornerRadius,
            yRadius: style.highlightCornerRadius
        ).fill()
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
        let style = annotationStyle(for: document, imageRect: imageRect, appearance: annotation.appearance)
        let annotationRect = annotation.rect(in: imageRect)
        let rect = annotation.rect(in: imageRect).applying(sourceViewTransform).expandedToMinimumSize(width: 120, height: 34)
        let field = NSTextField(frame: rect)
        field.stringValue = annotation.text.isEmpty ? L10n.defaultAnnotationText : annotation.text
        field.font = annotation.appearance.textFont(size: style.textFontSize(for: annotationRect))
        field.textColor = style.color
        field.alignment = annotation.appearance.textAlignment?.nsAlignment ?? .center
        field.isBordered = annotation.appearance.textBorderColor != nil
        field.drawsBackground = annotation.appearance.textBackgroundColor != nil
        field.backgroundColor = annotation.appearance.textBackgroundColor?.nsColor ?? .clear
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

        let pendingValue = field.currentEditor()?.string ?? field.stringValue
        let text = pendingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        if let fieldEditor = field.currentEditor(),
           window?.firstResponder === fieldEditor {
            window?.makeFirstResponder(self)
        }
        field.removeFromSuperview()
        activeTextField = nil
        editingTextAnnotationID = nil

        if text.isEmpty {
            annotations.removeAll { $0.id == id }
            selectedAnnotationID = nil
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].text = text
            if let document { annotations[index] = annotations[index].fittingFontBounds(in: document.sourcePixelSize) }
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

    private func drawLine(
        points: [CGPoint],
        style: CaptureAnnotationStyle,
        alpha: CGFloat
    ) {
        guard points.count >= 2 else {
            return
        }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.lineWidth
        path.move(to: points[0])
        path.line(to: points[1])

        style.color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawBrush(
        points: [CGPoint],
        style: CaptureAnnotationStyle,
        alpha: CGFloat
    ) {
        guard points.count >= 2 else {
            return
        }
        let path = CaptureAnnotationPaths.brush(points, smoothing: style.appearance.brushSmoothing ?? 0)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.brushWidth
        style.color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawPixelatedRegion(
        annotation: CaptureAnnotation,
        rect: CGRect,
        document: CaptureDocument,
        shouldCache: Bool
    ) {
        guard let pixelated = pixelatedImage(
            for: annotation,
            document: document,
            shouldCache: shouldCache
        ) else {
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()
            return
        }
        pixelated.draw(
            in: rect,
            from: NSRect(origin: .zero, size: pixelated.size),
            operation: .sourceOver,
            fraction: CaptureAnnotationStyle.mosaicOpacity,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawSelection(for annotation: CaptureAnnotation, imageRect: CGRect) {
        switch annotation.kind {
        case .arrow, .curvedArrow, .line:
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
            if annotation.kind == .curvedArrow, points.count >= 3 {
                let guides = NSBezierPath(); guides.move(to: points[0]); guides.line(to: points[2]); guides.line(to: points[1])
                guides.lineWidth = 1; guides.setLineDash([2, 3], count: 2, phase: 0); guides.stroke()
                drawHandle(center: points[2])
            }
        case .rectangle, .ellipse, .filledRectangle, .spotlight, .blur, .counter, .text, .highlight, .mosaic, .brush:
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

    /// Test-visible entry point for proving that static mosaics reuse the same
    /// rendered region instead of rebuilding it on every AppKit redraw.
    func cachedPixelatedImage(for annotation: CaptureAnnotation) -> NSImage? {
        guard let document else {
            return nil
        }
        return pixelatedImage(for: annotation, document: document, shouldCache: true)
    }

    var mosaicCacheEntryCount: Int {
        mosaicCache.count
    }

    var mosaicCacheCostInPixels: Int {
        mosaicCachePixelCost
    }

    private func pixelatedImage(
        for annotation: CaptureAnnotation,
        document: CaptureDocument,
        shouldCache: Bool
    ) -> NSImage? {
        guard annotation.normalizedRect.width > 0,
              annotation.normalizedRect.height > 0
        else {
            return nil
        }

        let previewPixelSize = mosaicPreviewPixelSize(for: annotation, document: document)

        if shouldCache,
           let cached = mosaicCache[annotation.id],
           cached.documentSignature == documentSignature,
           cached.imageIdentity == ObjectIdentifier(document.image),
           cached.normalizedRect == annotation.normalizedRect,
           cached.previewPixelSize == previewPixelSize {
            return cached.image
        }

        guard let source = document.image.captureLabCGImage() else {
            return nil
        }

        guard let output = CapturePixelation.previewPixelatedImage(
            from: source,
            normalizedRect: annotation.normalizedRect,
            outputPixelSize: previewPixelSize
        ) else {
            return nil
        }

        let image = NSImage(
            cgImage: output,
            size: CGSize(width: output.width, height: output.height)
        )
        if shouldCache {
            storeMosaicCacheEntry(
                MosaicCacheEntry(
                    documentSignature: documentSignature,
                    imageIdentity: ObjectIdentifier(document.image),
                    normalizedRect: annotation.normalizedRect,
                    previewPixelSize: previewPixelSize,
                    image: image,
                    pixelCost: output.width * output.height
                ),
                for: annotation.id
            )
        }
        return image
    }

    private func storeMosaicCacheEntry(_ entry: MosaicCacheEntry, for id: UUID) {
        // Free a stale same-ID entry before considering its replacement. When
        // the cache is full, preserve the resident set instead of evicting it
        // during every sequential draw pass (classic LRU scan thrashing).
        removeMosaicCacheEntry(id)
        guard entry.pixelCost <= maximumMosaicCachePixelCost,
              mosaicCache.count < maximumMosaicCacheEntries,
              mosaicCachePixelCost <= maximumMosaicCachePixelCost - entry.pixelCost
        else {
            return
        }

        mosaicCache[id] = entry
        mosaicCachePixelCost += entry.pixelCost
    }

    private func removeMosaicCacheEntry(_ id: UUID) {
        if let removed = mosaicCache.removeValue(forKey: id) {
            mosaicCachePixelCost -= removed.pixelCost
        }
    }

    private func pruneMosaicCache() {
        let liveMosaicIDs = Set(
            annotations.lazy
                .filter { $0.kind == .mosaic }
                .map(\.id)
        )
        for id in Array(mosaicCache.keys) where !liveMosaicIDs.contains(id) {
            removeMosaicCacheEntry(id)
        }
    }

    private func clearMosaicCache() {
        mosaicCache.removeAll(keepingCapacity: true)
        mosaicCachePixelCost = 0
    }

    private func mosaicPreviewPixelSize(
        for annotation: CaptureAnnotation,
        document: CaptureDocument
    ) -> CGSize {
        let sourcePixelSize = document.sourcePixelSize
        let sourceCrop = CapturePixelation.cropRect(
            for: annotation.normalizedRect,
            pixelSize: sourcePixelSize
        )
        let displayRect = annotation.rect(in: imageDisplayRect(for: document.image.size))
        let backingScale = max(window?.backingScaleFactor ?? 1, 1)
        var width = max(
            1,
            min(Int(sourceCrop.width), Int((displayRect.width * backingScale).rounded(.up)))
        )
        var height = max(
            1,
            min(Int(sourceCrop.height), Int((displayRect.height * backingScale).rounded(.up)))
        )

        let pixelCost = width * height
        if pixelCost > maximumMosaicPreviewPixelCost {
            let scale = sqrt(CGFloat(maximumMosaicPreviewPixelCost) / CGFloat(pixelCost))
            width = max(1, Int((CGFloat(width) * scale).rounded(.down)))
            height = max(1, Int((CGFloat(height) * scale).rounded(.down)))

            // Floating-point rounding should already put the result below the
            // limit. This final adjustment makes the memory invariant exact.
            while width * height > maximumMosaicPreviewPixelCost {
                if width >= height {
                    width -= 1
                } else {
                    height -= 1
                }
            }
        }

        return CGSize(width: width, height: height)
    }

    private func annotationStyle(
        for document: CaptureDocument,
        imageRect: CGRect,
        appearance: CaptureAnnotationAppearance = .init()
    ) -> CaptureAnnotationStyle {
        CaptureAnnotationStyle(
            sourcePixelSize: document.sourcePixelSize,
            renderedImageSize: imageRect.size,
            appearance: appearance
        )
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
        let raw = rawCanvasPoint(for: event)
        if selectedTool == .crop { return raw }
        return CaptureGeometry.clamped(raw, to: outputDisplayRect).applying(sourceViewTransform.inverted())
    }

    private func rawCanvasPoint(for event: NSEvent) -> CGPoint {
        guard window != nil else {
            return event.locationInWindow
        }
        return convert(event.locationInWindow, from: nil)
    }

    private static func signature(for document: CaptureDocument) -> String {
        let pixelSize = document.sourcePixelSize
        return [
            document.id.uuidString,
            "\(ObjectIdentifier(document.image))",
            "\(document.geometry)",
            document.sourceURL?.path ?? "capture",
            "\(document.createdAt.timeIntervalSinceReferenceDate)",
            "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        ].joined(separator: "|")
    }
}

private struct HandleHit {
    let interaction: Interaction
}

private struct MosaicCacheEntry {
    let documentSignature: String?
    let imageIdentity: ObjectIdentifier
    let normalizedRect: CGRect
    let previewPixelSize: CGSize
    let image: NSImage
    let pixelCost: Int
}

private enum Interaction {
    case adjustingCrop(original: CGRect, handle: ResizeHandle?, start: CGPoint)
    case cropping(start: CGPoint, current: CGPoint)
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
    case control

    var index: Int { switch self { case .start: return 0; case .end: return 1; case .control: return 2 } }
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
