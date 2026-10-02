import AppKit
import SwiftUI

@MainActor
final class CaptureRegionSelection: ObservableObject {
    @Published var rect = CGRect.zero
    @Published var ratio = "Free"
    @Published var width = "640" {
        didSet { if !updatingFields { editedHeight = false } }
    }
    @Published var height = "480" {
        didSet { if !updatingFields { editedHeight = true } }
    }
    @Published var locksRatio = false {
        didSet {
            guard locksRatio != oldValue else { return }
            if locksRatio, let w = Double(width), let h = Double(height),
               w.isFinite, h.isFinite, w > 0, h > 0, (w / h).isFinite {
                lockedAspect = w / h
            } else {
                lockedAspect = nil
            }
        }
    }
    private var lockedAspect: CGFloat?
    private var updatingFields = false
    private var editedHeight = false
    @Published var showsGuides = true
    @Published var showsMagnifier = true
    @Published var error: String?
    var displays: [CaptureDisplay] = []
    var pointer = CGPoint.zero
    var didChange: (() -> Void)?
    var finish: (() -> Void)?
    var cancel: (() -> Void)?
    var bounds: CGRect { displays.reduce(.null) { $0.union($1.frame) } }
    var aspect: CGFloat? {
        switch ratio {
        case "1:1": return 1
        case "4:3": return 4.0 / 3
        case "16:9": return 16.0 / 9
        case "9:16": return 9.0 / 16
        default:
            return locksRatio ? lockedAspect : nil
        }
    }
    var dimensions: String {
        guard let pixels = PreciseCaptureGeometry.outputSize(rect, displays: displays) else {
            return L10n.text(en: "Drag to select a region", zh: "拖动鼠标选择区域")
        }
        return "\(String(format: "%.1f × %.1f", rect.width, rect.height)) pt → \(Int(pixels.width)) × \(Int(pixels.height)) px"
    }
    func setRect(_ value: CGRect, updateFields: Bool = true) {
        rect = value
        if updateFields {
            updatingFields = true
            width = String(format: "%.1f", value.width)
            height = String(format: "%.1f", value.height)
            updatingFields = false
            editedHeight = false
        }
        error = nil
        didChange?()
    }
    func applySize() {
        guard let w = Double(width), let h = Double(height), w.isFinite, h.isFinite, w > 0, h > 0 else {
            error = L10n.text(en: "Enter positive width and height in points.", zh: "请输入大于零的宽高，单位为点。")
            return
        }
        let size: CGSize
        if let aspect {
            size = editedHeight ? CGSize(width: h * aspect, height: h) : CGSize(width: w, height: w / aspect)
        } else {
            size = CGSize(width: w, height: h)
        }
        guard size.width <= bounds.width, size.height <= bounds.height else {
            error = L10n.text(en: "The size exceeds the desktop.", zh: "尺寸超出桌面范围。")
            return
        }
        let origin = rect.hasPositiveArea ? rect.origin : CGPoint(x: pointer.x, y: pointer.y - size.height)
        let value = PreciseCaptureGeometry.moved(CGRect(origin: origin, size: size), dx: 0, dy: 0, bounds: bounds)
        guard PreciseCaptureGeometry.outputSize(value, displays: displays) != nil else {
            error = L10n.text(en: "The selection is outside a display or too large (80 MP maximum).", zh: "选区不在显示器内或过大（最多 8000 万像素）。")
            return
        }
        setRect(value)
    }
    func nudge(key: UInt16, shift: Bool, resize: Bool) {
        guard rect.hasPositiveArea else { return }
        let step: CGFloat = shift ? 10 : 1
        let dx: CGFloat = key == 123 ? -step : key == 124 ? step : 0
        let dy: CGFloat = key == 125 ? -step : key == 126 ? step : 0
        if resize {
            var value = rect
            value.size.width = max(1, value.width + dx)
            value.size.height = max(1, value.height + dy)
            if let aspect { if dx != 0 { value.size.height = value.width / aspect } else { value.size.width = value.height * aspect } }
            if bounds.contains(value) { setRect(value) }
        } else { setRect(PreciseCaptureGeometry.moved(rect, dx: dx, dy: dy, bounds: bounds)) }
    }
}

@MainActor
final class CaptureRegionSelector {
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CGRect, Error>?
    private var observer: NSObjectProtocol?
    private var selection: CaptureRegionSelection?

    func select(displays: [CaptureDisplay], frames: [String: CGImage], frozen: Bool) async throws -> CGRect {
        guard continuation == nil else { throw CaptureLabError.captureCancelled }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let state = CaptureRegionSelection()
                state.displays = displays
                state.pointer = NSEvent.mouseLocation
                state.finish = { [weak self, weak state] in
                    guard let self, let state else { return }
                    guard PreciseCaptureGeometry.outputSize(state.rect, displays: displays) != nil else {
                        state.error = L10n.text(en: "Select a valid region (80 MP maximum).", zh: "请选择有效区域（最多 8000 万像素）。")
                        return
                    }
                    self.complete(.success(state.rect))
                }
                state.cancel = { [weak self] in self?.complete(.failure(CaptureLabError.captureCancelled)) }
                self.selection = state
                for display in displays {
                    let panel = RegionPanel(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    panel.level = .screenSaver
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                    panel.backgroundColor = .clear
                    panel.isOpaque = false
                    panel.hasShadow = false
                    panel.acceptsMouseMovedEvents = true
                    panel.isReleasedWhenClosed = false
                    let view = RegionSelectionView(state: state, display: display, snapshot: frames[display.id], frozen: frozen)
                    panel.contentView = view
                    panels.append(panel)
                    panel.orderFrontRegardless()
                    if display.frame.contains(state.pointer) { panel.makeKey(); panel.makeFirstResponder(view) }
                }
                let screen = NSScreen.screens.first { $0.frame.contains(state.pointer) } ?? NSScreen.screens.first
                let frame = screen?.visibleFrame ?? state.bounds
                let width = min(760.0, frame.width - 24)
                let options = RegionPanel(contentRect: CGRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: 174),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                options.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
                options.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                options.isReleasedWhenClosed = false
                options.contentView = NSHostingView(rootView: RegionOptionsView(state: state, frozen: frozen))
                panels.append(options)
                options.orderFrontRegardless()
                state.didChange = { [weak self] in self?.panels.forEach { $0.contentView?.needsDisplay = true } }
                observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.complete(.failure(CaptureLabError.captureFailed(L10n.invalidLastRegion))) }
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(.failure(CancellationError())) }
        }
    }

    private func complete(_ result: Result<CGRect, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        selection = nil
        continuation.resume(with: result)
    }
}

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { (contentView as? RegionSelectionView)?.state.cancel?() }
}

@MainActor
final class RegionSelectionView: NSView {
    let state: CaptureRegionSelection
    let display: CaptureDisplay
    let snapshot: CGImage?
    let frozen: Bool
    private var start = CGPoint.zero
    private var original: CGRect?
    private var dragRatio: CGFloat?
    private var magnifier: CGImage?
    private var lastMagnifierTime = Date.distantPast

    init(state: CaptureRegionSelection, display: CaptureDisplay, snapshot: CGImage?, frozen: Bool) {
        self.state = state; self.display = display; self.snapshot = snapshot; self.frozen = frozen
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        setAccessibilityLabel(L10n.text(en: "Capture region. Drag to select, arrows to move, Return to capture, Escape to cancel.", zh: "截图区域。拖动框选，方向键移动，回车截图，Esc 取消。"))
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        start = NSEvent.mouseLocation
        original = state.rect.contains(start) ? state.rect : nil
        dragRatio = state.aspect
        if original == nil { state.setRect(CGRect(origin: start, size: .zero), updateFields: false) }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if let original {
            state.setRect(PreciseCaptureGeometry.moved(original, dx: point.x - start.x, dy: point.y - start.y, bounds: state.bounds))
        } else {
            state.setRect(PreciseCaptureGeometry.constrainedRect(from: start, to: point, ratio: dragRatio, bounds: state.bounds), updateFields: false)
        }
        updatePointer()
    }
    override func mouseUp(with event: NSEvent) { state.setRect(state.rect) }
    override func mouseMoved(with event: NSEvent) { updatePointer() }
    override func rightMouseDown(with event: NSEvent) { state.cancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: state.cancel?()
        case 36, 76: state.finish?()
        case 123...126: state.nudge(key: event.keyCode, shift: event.modifierFlags.contains(.shift), resize: event.modifierFlags.contains(.option))
        default: super.keyDown(with: event)
        }
    }
    private func updatePointer() {
        state.pointer = NSEvent.mouseLocation
        if state.showsMagnifier, Date().timeIntervalSince(lastMagnifierTime) > 0.03 {
            lastMagnifierTime = Date()
            let sample = CGRect(x: state.pointer.x - 12, y: state.pointer.y - 12, width: 24, height: 24)
            if frozen, let snapshot {
                magnifier = snapshot.cropping(to: PreciseCaptureGeometry.sourceRect(sample, display: display, imageSize: CGSize(width: snapshot.width, height: snapshot.height)))
            } else if let window {
                let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
                let quartz = CGRect(x: sample.minX, y: mainTop - sample.maxY, width: 24, height: 24)
                magnifier = CGWindowListCreateImage(quartz, .optionOnScreenBelowWindow, CGWindowID(window.windowNumber), [.bestResolution])
            }
        }
        state.didChange?()
    }
    override func draw(_ dirtyRect: NSRect) {
        if frozen, let snapshot { NSImage(cgImage: snapshot, size: bounds.size).draw(in: bounds) }
        let selected = state.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let shade = NSBezierPath(rect: bounds)
        if state.rect.hasPositiveArea { shade.appendRect(selected); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.28).setFill(); shade.fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selected); border.lineWidth = 1; border.stroke()
        let point = CGPoint(x: state.pointer.x - display.frame.minX, y: state.pointer.y - display.frame.minY)
        if state.showsGuides {
            let guides = NSBezierPath()
            guides.move(to: CGPoint(x: point.x, y: bounds.minY)); guides.line(to: CGPoint(x: point.x, y: bounds.maxY))
            guides.move(to: CGPoint(x: bounds.minX, y: point.y)); guides.line(to: CGPoint(x: bounds.maxX, y: point.y))
            guides.setLineDash([3, 3], count: 2, phase: 0); guides.lineWidth = 0.5; guides.stroke()
        }
        if state.showsMagnifier, display.frame.contains(state.pointer), let magnifier {
            let target = CGRect(x: min(max(8, point.x + 24), bounds.width - 136), y: min(max(8, point.y + 24), bounds.height - 136), width: 128, height: 128)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: magnifier, size: .zero).draw(in: target)
            NSColor.white.setStroke(); NSBezierPath(rect: target).stroke()
            NSColor.systemRed.setStroke()
            let cross = NSBezierPath(); cross.move(to: CGPoint(x: target.midX - 8, y: target.midY)); cross.line(to: CGPoint(x: target.midX + 8, y: target.midY))
            cross.move(to: CGPoint(x: target.midX, y: target.midY - 8)); cross.line(to: CGPoint(x: target.midX, y: target.midY + 8)); cross.stroke()
        }
    }
}

private struct RegionOptionsView: View {
    @ObservedObject var state: CaptureRegionSelection
    let frozen: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(frozen ? L10n.frozenRegion : L10n.captureRegion).font(.headline)
                Spacer()
                Text(state.dimensions).monospacedDigit()
            }
            HStack {
                TextField(L10n.text(en: "Width (pt)", zh: "宽 (pt)"), text: $state.width).frame(width: 78)
                Text("×")
                TextField(L10n.text(en: "Height (pt)", zh: "高 (pt)"), text: $state.height).frame(width: 78)
                Picker(L10n.text(en: "Ratio", zh: "比例"), selection: $state.ratio) {
                    Text(L10n.text(en: "Free", zh: "自由")).tag("Free")
                    ForEach(["1:1", "4:3", "16:9", "9:16"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 130)
                Toggle(L10n.text(en: "Lock", zh: "锁定"), isOn: $state.locksRatio)
                Button(L10n.text(en: "Apply size", zh: "应用尺寸"), action: state.applySize)
            }.textFieldStyle(.roundedBorder).onSubmit { state.applySize() }
            HStack {
                Toggle(L10n.text(en: "Guides", zh: "参考线"), isOn: $state.showsGuides)
                Toggle(L10n.text(en: "Magnifier", zh: "放大镜"), isOn: $state.showsMagnifier)
                Spacer()
                Button(L10n.cancel) { state.cancel?() }.keyboardShortcut(.cancelAction)
                Button(L10n.captureMenu) { state.finish?() }.keyboardShortcut(.defaultAction).disabled(!state.rect.hasPositiveArea)
            }
            Text(state.error ?? L10n.text(en: "Drag inside to move · Arrows: 1 pt · Shift: 10 pt · Option: resize · Return: capture", zh: "拖动选区内部移动 · 方向键：1 点 · Shift：10 点 · Option：调整尺寸 · 回车：截图"))
                .font(.caption).foregroundColor(state.error == nil ? .secondary : .red)
        }
        .padding(14)
        .background(.regularMaterial)
        .onChange(of: state.ratio) { _ in if state.rect.hasPositiveArea { state.applySize() } }
        .onChange(of: state.showsGuides) { _ in state.didChange?() }
        .onChange(of: state.showsMagnifier) { _ in state.didChange?() }
    }
}
