import AppKit
import SwiftUI

/// A document object list and inspector shared by image and annotation objects.
/// The parent commits both arrays together to one undoable document edit.
struct CaptureLayersView: View {
    let document: CaptureDocument
    let annotations: [CaptureAnnotation]
    let selectedObjects: Set<CaptureObjectID>
    let onSelectionChanged: (Set<CaptureObjectID>) -> Void
    let onCommit: ([CaptureImageLayer], [CaptureAnnotation]) -> Void
    let addImages: () -> Void
    @State private var rotation = "0"
    @State private var width = "0"
    @State private var height = "0"
    @State private var error: String?

    private var selection: Binding<Set<CaptureObjectID>> {
        Binding(get: { selectedObjects }, set: { onSelectionChanged($0) })
    }
    private var singleImage: CaptureImageLayer? {
        guard selectedObjects.count == 1, case .image(let id) = selectedObjects.first else { return nil }
        return document.imageLayers.first { $0.id == id }
    }
    private var hasSelectedImages: Bool {
        document.imageLayers.contains { selectedObjects.contains(.image($0.id)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text(en: "Objects", zh: "对象")).font(.headline)
                Spacer()
                Button(action: addImages) { Image(systemName: "photo.badge.plus") }
                    .help(L10n.text(en: "Add images to this canvas", zh: "向当前画布添加图片"))
                    .accessibilityLabel(L10n.text(en: "Add images", zh: "添加图片"))
            }
            Text(L10n.text(en: "Shift-click or drag an empty area to select multiple objects. Drag to move; arrow keys nudge; Shift accelerates.",
                           zh: "Shift 点选或在空白处拖动以多选。拖动可组合移动，方向键微调，Shift 加速。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(selection: selection) {
                Section(L10n.text(en: "Annotations (above images)", zh: "标注（位于图片上方）")) {
                    ForEach(annotations.reversed()) { annotation in
                        Label(annotation.kind == .text ? String(annotation.text.prefix(30)) : annotation.kind.displayTitle,
                              systemImage: "pencil.tip.crop.circle")
                            .tag(CaptureObjectID.annotation(annotation.id))
                    }
                }
                Section(L10n.text(en: "Images (front to back)", zh: "图片（从前到后）")) {
                    ForEach(CaptureLayerComposition.ordered(document.imageLayers).reversed()) { layer in
                        Label(layer.name, systemImage: "photo").lineLimit(1)
                            .tag(CaptureObjectID.image(layer.id))
                    }
                }
            }
            .listStyle(.sidebar).frame(minHeight: 140, maxHeight: 270)
            .onDeleteCommand(perform: deleteSelection)
            HStack {
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .keyboardShortcut("d", modifiers: .command)
                    .help(L10n.text(en: "Duplicate selection (⌘D)", zh: "复制选中对象（⌘D）"))
                    .accessibilityLabel(L10n.text(en: "Duplicate selection", zh: "复制选中对象"))
                Button(action: deleteSelection) { Image(systemName: "trash") }
                .help(L10n.text(en: "Delete selection (Delete)", zh: "删除选中对象（Delete）"))
                .accessibilityLabel(L10n.text(en: "Delete selection", zh: "删除选中对象"))
                Spacer()
                Button { reorder(forward: false) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                    .disabled(!hasSelectedImages)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(L10n.text(en: "Move image backward", zh: "图片下移一层"))
                    .accessibilityLabel(L10n.text(en: "Move image backward", zh: "图片下移一层"))
                Button { reorder(forward: true) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                    .disabled(!hasSelectedImages)
                    .keyboardShortcut("]", modifiers: .command)
                    .help(L10n.text(en: "Move image forward", zh: "图片上移一层"))
                    .accessibilityLabel(L10n.text(en: "Move image forward", zh: "图片上移一层"))
            }.disabled(selectedObjects.isEmpty)
            Menu(L10n.text(en: "Align and arrange", zh: "对齐与排列")) {
                ForEach(CaptureObjectArrangement.allCases, id: \.self) { arrangement in
                    Button(arrangement.title) {
                        let result = CaptureObjectOperations.arranged(arrangement, layers: document.imageLayers,
                                                                     annotations: annotations, selection: selectedObjects)
                        onCommit(result.layers, result.annotations)
                    }
                }
            }.disabled(selectedObjects.count < 2)
            if singleImage != nil {
                Divider()
                Text(L10n.text(en: "Image transform", zh: "图片变换")).font(.subheadline.weight(.medium))
                HStack {
                    Text(L10n.text(en: "Rotation", zh: "旋转"))
                    TextField("°", text: $rotation).textFieldStyle(.roundedBorder).onSubmit(applyTransform)
                        .accessibilityLabel(L10n.text(en: "Image rotation in degrees", zh: "图片旋转角度"))
                    Text("°")
                }
                HStack {
                    Text(L10n.text(en: "W / H", zh: "宽 / 高"))
                    TextField("%", text: $width).textFieldStyle(.roundedBorder).onSubmit(applyTransform)
                        .accessibilityLabel(L10n.text(en: "Image width, percent of source", zh: "图片宽度，占原图百分比"))
                    TextField("%", text: $height).textFieldStyle(.roundedBorder).onSubmit(applyTransform)
                        .accessibilityLabel(L10n.text(en: "Image height, percent of source", zh: "图片高度，占原图百分比"))
                    Text("%")
                }
                Button(L10n.text(en: "Apply transform", zh: "应用变换"), action: applyTransform)
                Text(L10n.text(en: "Drag a corner to resize; Shift keeps proportions. Drag the round handle to rotate; Shift snaps to 15°.",
                               zh: "拖动角点缩放，Shift 保持比例；拖动圆形手柄旋转，Shift 吸附到 15°。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12).frame(minWidth: 240, idealWidth: 270, maxWidth: 310)
        .onAppear(perform: synchronizeInspector)
        .onChange(of: singleImage) { _ in synchronizeInspector() }
    }

    private func synchronizeInspector() {
        guard let layer = singleImage else { return }
        rotation = String(format: "%.1f", layer.rotationDegrees)
        width = String(format: "%.1f", layer.normalizedRect.width * 100)
        height = String(format: "%.1f", layer.normalizedRect.height * 100)
    }

    private func applyTransform() {
        guard var layer = singleImage, let degrees = Double(rotation), degrees.isFinite,
              let w = Double(width), let h = Double(height), w.isFinite, h.isFinite,
              w > 0, h > 0, w <= 100, h <= 100 else {
            error = L10n.text(en: "Enter a finite angle and a width/height from 0 to 100%.", zh: "请输入有效角度，宽高需大于 0 且不超过 100%。")
            return
        }
        let center = CGPoint(x: layer.normalizedRect.midX, y: layer.normalizedRect.midY)
        layer.rotationDegrees = degrees.truncatingRemainder(dividingBy: 360)
        layer.normalizedRect = CGRect(x: min(max(0, center.x - w / 200), 1 - w / 100),
                                      y: min(max(0, center.y - h / 200), 1 - h / 100), width: w / 100, height: h / 100)
        onCommit(document.imageLayers.map { $0.id == layer.id ? layer : $0 }, annotations)
        error = nil
    }

    private func duplicate() {
        do {
            let result = try CaptureObjectOperations.duplicated(layers: document.imageLayers, annotations: annotations, selection: selectedObjects)
            onCommit(result.layers, result.annotations); onSelectionChanged(result.selection); error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func deleteSelection() {
        let result = CaptureObjectOperations.deleted(layers: document.imageLayers, annotations: annotations, selection: selectedObjects)
        onCommit(result.layers, result.annotations); onSelectionChanged([])
    }

    private func reorder(forward: Bool) {
        onCommit(CaptureObjectOperations.reorder(document.imageLayers, selection: selectedObjects, bringForward: forward), annotations)
    }
}

struct CaptureLayersCanvasView: NSViewRepresentable {
    let document: CaptureDocument
    let annotations: [CaptureAnnotation]
    let selection: Set<CaptureObjectID>
    let onSelectionChanged: (Set<CaptureObjectID>) -> Void
    let onCommit: ([CaptureImageLayer], [CaptureAnnotation]) -> Void
    var zoomLevel: CaptureZoomLevel = .fit
    var onError: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> CaptureLayersNSCanvasView {
        let view = CaptureLayersNSCanvasView(); configure(view); return view
    }
    func updateNSView(_ view: CaptureLayersNSCanvasView, context: Context) { configure(view) }
    private func configure(_ view: CaptureLayersNSCanvasView) {
        view.synchronize(document: document, annotations: annotations, selection: selection, zoom: zoomLevel)
        view.onSelectionChanged = onSelectionChanged
        view.onCommit = onCommit
        view.onError = onError
    }
}

@MainActor
final class CaptureLayersNSCanvasView: NSView {
    private(set) var document: CaptureDocument?
    private(set) var layers: [CaptureImageLayer] = []
    private(set) var annotations: [CaptureAnnotation] = []
    private(set) var selection: Set<CaptureObjectID> = []
    private var zoom: CaptureZoomLevel = .fit
    var onSelectionChanged: (Set<CaptureObjectID>) -> Void = { _ in }
    var onCommit: ([CaptureImageLayer], [CaptureAnnotation]) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }
    private var preview: NSImage?
    private var previewIsValid = false
    private var gesture: Gesture?
    private var marquee: CGRect?
    private var guides: [CGFloat] = []

    private struct Gesture {
        enum Kind { case move, resize(UUID, Int), rotate(UUID), marquee }
        var kind: Kind
        var origin: CGPoint
        var layers: [CaptureImageLayer]
        var annotations: [CaptureAnnotation]
        var selection: Set<CaptureObjectID>
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text(en: "Object canvas. Shift-click for multiple selection. Arrow keys move; Delete removes; Command-D duplicates.",
                                       zh: "对象画布。Shift 点选多选，方向键移动，Delete 删除，Command-D 复制。"))
    }
    required init?(coder: NSCoder) { nil }

    func synchronize(document: CaptureDocument, annotations: [CaptureAnnotation], selection: Set<CaptureObjectID>, zoom: CaptureZoomLevel) {
        let changed = self.document?.id != document.id || self.document?.imageLayers != document.imageLayers ||
            self.document?.geometry != document.geometry || (gesture?.annotations ?? self.annotations) != annotations || self.zoom != zoom
        if changed {
            gesture = nil; marquee = nil; guides = []
            layers = document.imageLayers; self.annotations = annotations; previewIsValid = false
        } else if gesture == nil {
            layers = document.imageLayers; self.annotations = annotations
        }
        self.document = document; self.selection = selection; self.zoom = zoom
        needsDisplay = true
    }

    var outputDisplayRect: CGRect {
        guard let document else { return .zero }
        let content = bounds.insetBy(dx: 80, dy: 60)
        if let scale = zoom.scale {
            let size = CGSize(width: document.displaySize.width * scale, height: document.displaySize.height * scale)
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        }
        let fit = CaptureGeometry.aspectFitRect(imageSize: document.displaySize,
                                               in: CGSize(width: max(1, content.width), height: max(1, content.height)))
        return fit.offsetBy(dx: content.minX, dy: content.minY)
    }

    private var sourceToView: CGAffineTransform {
        guard let document else { return .identity }
        let out = outputDisplayRect
        return document.geometry.transform
            .concatenating(CGAffineTransform(scaleX: out.width / document.canvasSize.width, y: out.height / document.canvasSize.height))
            .concatenating(CGAffineTransform(translationX: out.minX, y: out.minY))
    }

    func viewPoint(for normalizedPoint: CGPoint) -> CGPoint {
        guard let document else { return .zero }
        return CGPoint(x: normalizedPoint.x * document.sourcePixelSize.width, y: normalizedPoint.y * document.sourcePixelSize.height)
            .applying(sourceToView)
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint {
        guard let document else { return .zero }
        let source = point.applying(sourceToView.inverted())
        return CGPoint(x: source.x / document.sourcePixelSize.width, y: source.y / document.sourcePixelSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        guard let document else { return }
        if !previewIsValid {
            // Release the previous large bitmap before allocating a new one.
            preview = nil
            preview = autoreleasepool {
                CaptureLayerComposition.render(source: document.image, layers: layers)
                    .flatMap { $0.renderedWithCaptureLabAnnotations(annotations) }
                    .flatMap { document.applyingGeometry(to: $0) }
            }
            previewIsValid = true
        }
        preview?.draw(in: outputDisplayRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if preview == nil {
            let message = L10n.text(en: "The composition could not be rendered. Reduce the image size or remove an image.",
                                    zh: "无法渲染组合图片，请缩小图片尺寸或移除一张图片。")
            (message as NSString).draw(in: outputDisplayRect.insetBy(dx: 12, dy: 12),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }
        // Selection controls can extend into the canvas margin (in particular
        // the rotation handle of an image touching the top edge).
        for id in selection {
            let points = corners(for: id)
            guard points.count == 4 else { continue }
            let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
            path.lineWidth = 1.5; NSColor.controlAccentColor.setStroke(); path.stroke()
            if selection.count == 1, case .image = id {
                for p in points { drawHandle(p, round: false) }
                if let handle = rotationHandle(id) {
                    let line = NSBezierPath(); line.move(to: CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
                    line.line(to: handle); line.stroke(); drawHandle(handle, round: true)
                }
            }
        }
        if let marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill(); marquee.fill()
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: marquee).stroke()
        }
        if guides.count == 2 {
            NSColor.systemPink.setStroke()
            let v = NSBezierPath()
            v.move(to: viewPoint(for: CGPoint(x: guides[0], y: 0))); v.line(to: viewPoint(for: CGPoint(x: guides[0], y: 1)))
            v.move(to: viewPoint(for: CGPoint(x: 0, y: guides[1]))); v.line(to: viewPoint(for: CGPoint(x: 1, y: guides[1])))
            v.setLineDash([4, 3], count: 2, phase: 0); v.stroke()
        }
    }

    private func drawHandle(_ p: CGPoint, round: Bool) {
        let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
        let path = round ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
        NSColor.white.setFill(); path.fill(); NSColor.controlAccentColor.setStroke(); path.stroke()
    }

    private func corners(for id: CaptureObjectID) -> [CGPoint] {
        guard let document else { return [] }
        if case .image(let layerID) = id, let layer = layers.first(where: { $0.id == layerID }) {
            return layer.corners(in: document.sourcePixelSize).map { $0.applying(sourceToView) }
        }
        guard let rect = CaptureObjectOperations.rect(id, layers: layers, annotations: annotations) else { return [] }
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map(viewPoint)
    }

    private func rotationHandle(_ id: CaptureObjectID) -> CGPoint? {
        let p = corners(for: id); guard p.count == 4 else { return nil }
        let center = CGPoint(x: (p[0].x + p[2].x) / 2, y: (p[0].y + p[2].y) / 2)
        let top = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
        let length = max(0.001, hypot(top.x - center.x, top.y - center.y))
        return CGPoint(x: top.x + (top.x - center.x) * 22 / length, y: top.y + (top.y - center.y) * 22 / length)
    }

    private func select(_ ids: Set<CaptureObjectID>) { selection = ids; onSelectionChanged(ids); needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let point = normalizedPoint(p)
        let extending = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        var kind: Gesture.Kind = .move
        if selection.count == 1, let id = selection.first, case .image(let layerID) = id {
            if let handle = rotationHandle(id), hypot(p.x - handle.x, p.y - handle.y) < 9 { kind = .rotate(layerID) }
            else if let index = corners(for: id).firstIndex(where: { hypot(p.x - $0.x, p.y - $0.y) < 9 }) { kind = .resize(layerID, index) }
        }
        if case .move = kind {
            guard outputDisplayRect.contains(p) else { return }
            let hit = annotations.reversed().first { $0.normalizedBounds.insetBy(dx: -0.004, dy: -0.004).contains(point) }.map { CaptureObjectID.annotation($0.id) }
                ?? CaptureLayerComposition.ordered(layers).reversed().first { $0.contains(point, sourceSize: document.sourcePixelSize) }.map { .image($0.id) }
            if let hit {
                if extending {
                    var next = selection; if !next.insert(hit).inserted { next.remove(hit) }; select(next)
                } else if !selection.contains(hit) { select([hit]) }
            } else {
                if !extending { select([]) }
                kind = .marquee
            }
        }
        gesture = Gesture(kind: kind, origin: point, layers: layers, annotations: annotations, selection: selection)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let g = gesture, let document else { return }
        let raw = convert(event.locationInWindow, from: nil)
        // Rotation and resizing follow their controls beyond the image edge;
        // the resize branch constrains the resulting placement itself.
        let p: CGPoint
        switch g.kind {
        case .rotate, .resize: p = normalizedPoint(raw)
        case .move, .marquee: p = normalizedPoint(CaptureGeometry.clamped(raw, to: outputDisplayRect))
        }
        switch g.kind {
        case .move:
            var dx = p.x - g.origin.x, dy = p.y - g.origin.y
            guides = []
            if g.selection.count == 1, let id = g.selection.first,
               let r = CaptureObjectOperations.rect(id, layers: g.layers, annotations: g.annotations) {
                let targetX = r.midX + dx, targetY = r.midY + dy
                let others = g.layers.filter { !g.selection.contains(.image($0.id)) }.map(\.normalizedRect)
                    + g.annotations.filter { !g.selection.contains(.annotation($0.id)) }.map(\.normalizedBounds)
                let xs = [CGFloat(0.5)] + others.map(\.midX), ys = [CGFloat(0.5)] + others.map(\.midY)
                let threshold = 5 / max(1, outputDisplayRect.width)
                let snapX = xs.min { abs($0 - targetX) < abs($1 - targetX) }
                let snapY = ys.min { abs($0 - targetY) < abs($1 - targetY) }
                if let snapX, abs(snapX - targetX) < threshold { dx += snapX - targetX }
                if let snapY, abs(snapY - targetY) < threshold { dy += snapY - targetY }
                if dx != p.x - g.origin.x || dy != p.y - g.origin.y { guides = [r.midX + dx, r.midY + dy] }
            }
            let result = CaptureObjectOperations.translated(layers: g.layers, annotations: g.annotations, selection: g.selection, dx: dx, dy: dy)
            layers = result.layers; annotations = result.annotations; previewIsValid = false
        case .resize(let id, let corner):
            guard let index = g.layers.firstIndex(where: { $0.id == id }) else { return }
            var layer = g.layers[index]
            let r = layer.normalizedRect
            // Resize in the rotated image's local pixel axes around its center.
            // A fixed center avoids a jump when crossing 90 degrees.
            let angle = -layer.rotationDegrees * .pi / 180
            let dx = (p.x - r.midX) * document.sourcePixelSize.width
            let dy = (p.y - r.midY) * document.sourcePixelSize.height
            let localX = dx * cos(angle) - dy * sin(angle)
            let localY = dx * sin(angle) + dy * cos(angle)
            let xSign: CGFloat = corner == 0 || corner == 3 ? -1 : 1
            let ySign: CGFloat = corner < 2 ? -1 : 1
            var w = max(0.004, 2 * localX * xSign / document.sourcePixelSize.width)
            var h = max(0.004, 2 * localY * ySign / document.sourcePixelSize.height)
            if event.modifierFlags.contains(.shift) {
                let scale = max(w / r.width, h / r.height)
                w = r.width * scale; h = r.height * scale
            }
            let fit = min(1, min(2 * min(r.midX, 1 - r.midX) / w, 2 * min(r.midY, 1 - r.midY) / h))
            w *= fit; h *= fit
            layer.normalizedRect = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
            layers = g.layers; layers[index] = layer; previewIsValid = false
        case .rotate(let id):
            guard let index = g.layers.firstIndex(where: { $0.id == id }) else { return }
            let original = g.layers[index]
            let r = original.normalizedRect
            let originAngle = atan2((g.origin.y - r.midY) * document.sourcePixelSize.height,
                                    (g.origin.x - r.midX) * document.sourcePixelSize.width)
            let angle = atan2((p.y - r.midY) * document.sourcePixelSize.height,
                              (p.x - r.midX) * document.sourcePixelSize.width)
            var degrees = original.rotationDegrees + (angle - originAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            layers = g.layers; layers[index].rotationDegrees = degrees.truncatingRemainder(dividingBy: 360); previewIsValid = false
        case .marquee:
            let start = viewPoint(for: g.origin)
            marquee = CGRect(x: min(start.x, raw.x), y: min(start.y, raw.y), width: abs(raw.x - start.x), height: abs(raw.y - start.y))
            let all = layers.map { CaptureObjectID.image($0.id) } + annotations.map { .annotation($0.id) }
            let inside = all.filter { id in corners(for: id).allSatisfy { marquee?.contains($0) == true } }
            select(g.selection.union(inside))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let g = gesture else { return }
        gesture = nil; marquee = nil; guides = []
        if layers != g.layers || annotations != g.annotations { onCommit(layers, annotations) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let g = gesture { layers = g.layers; annotations = g.annotations; select(g.selection); previewIsValid = false }
            else { select([]) }
            gesture = nil; marquee = nil; guides = []; needsDisplay = true; return
        }
        if let g = gesture {
            // A keyboard edit during a pointer gesture starts from the last
            // committed state, avoiding a second mouseUp commit afterward.
            layers = g.layers; annotations = g.annotations; selection = g.selection
            gesture = nil; marquee = nil; guides = []; previewIsValid = false
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            select(Set(layers.map { .image($0.id) } + annotations.map { .annotation($0.id) })); return
        }
        guard !selection.isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 51 || event.keyCode == 117 {
            let result = CaptureObjectOperations.deleted(layers: layers, annotations: annotations, selection: selection)
            commit(result); select([]); return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d" {
            do {
                let result = try CaptureObjectOperations.duplicated(layers: layers, annotations: annotations, selection: selection)
                commit((result.layers, result.annotations)); select(result.selection)
            } catch { onError(error.localizedDescription) }
            return
        }
        guard let document, [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        let speed: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        // Keyboard directions are screen directions after crop/rotation/flip.
        let dx: CGFloat = event.keyCode == 123 ? -speed : event.keyCode == 124 ? speed : 0
        let dy: CGFloat = event.keyCode == 126 ? -speed : event.keyCode == 125 ? speed : 0
        let t = document.geometry.transform.inverted()
        let delta = CGPoint(x: dx, y: dy).applying(t), origin = CGPoint.zero.applying(t)
        commit(CaptureObjectOperations.translated(layers: layers, annotations: annotations, selection: selection,
                                                  dx: (delta.x - origin.x) / document.sourcePixelSize.width,
                                                  dy: (delta.y - origin.y) / document.sourcePixelSize.height))
    }

    private func commit(_ result: (layers: [CaptureImageLayer], annotations: [CaptureAnnotation])) {
        layers = result.layers; annotations = result.annotations; previewIsValid = false
        onCommit(layers, annotations); needsDisplay = true
    }
}
