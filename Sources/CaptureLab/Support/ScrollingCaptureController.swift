import AppKit
import SwiftUI

@MainActor
final class ScrollingCaptureController: ObservableObject {
    static let shared = ScrollingCaptureController()
    @Published private(set) var direction: ScrollingCaptureDirection = .vertical
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var isStopped = false
    @Published private(set) var isBusy = false
    @Published private(set) var preview: NSImage?
    @Published private(set) var pendingPreview: NSImage?
    @Published private(set) var dimensions = ""
    @Published private(set) var segmentCount = 0
    @Published private(set) var message = ""
    @Published var leadingBand = 0
    @Published var trailingBand = 0
    @Published var seamPixels = 1
    @Published private(set) var maximumSeamPixels = 1
    private var captureTask: Task<ScrollingCaptureImage, Error>?
    private var finishRequested = false
    private var panel: ScrollingCapturePanel?
    private var outline: NSPanel?
    private let selector = CaptureRegionSelector()
    private var worker: ScrollingCaptureWorker?
    private var requestID: UUID?

    /// Caller hides its editor, pins, and quick-access windows until this completes, then routes
    /// the image through its normal capture history/document pipeline.
    func capture(direction: ScrollingCaptureDirection) async throws -> NSImage {
        guard !isRunning else { throw CaptureLabError.captureCancelled }
        try Task.checkCancellation()
        let id = UUID()
        requestID = id; isRunning = true; self.direction = direction
        finishRequested = false; isPaused = true; isStopped = false; isBusy = false
        preview = nil; pendingPreview = nil; segmentCount = 0
        leadingBand = 0; trailingBand = 0; seamPixels = 1
        message = L10n.text(en: "Set any fixed edge bands, then press Resume and scroll slowly inside your selection.", zh: "如有固定边栏请先设置，然后点击继续并在选区内缓慢滚动。")
        let task = Task { try await self.run(id: id, direction: direction) }
        captureTask = task
        return try await withTaskCancellationHandler {
            defer {
                if requestID == id {
                    panel?.orderOut(nil); panel?.close(); panel = nil
                    outline?.orderOut(nil); outline?.close(); outline = nil
                    captureTask = nil; worker = nil; requestID = nil; isRunning = false
                    preview = nil; pendingPreview = nil
                }
            }
            let result = try await task.value
            return NSImage(cgImage: result.image, size: .zero)
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() { captureTask?.cancel() }
    func finish() { guard !isBusy else { return }; finishRequested = true }
    func togglePause() {
        guard !isStopped, !isBusy else { return }
        isPaused.toggle()
        message = isPaused
            ? L10n.text(en: "Paused. Review the image or adjust the last seam.", zh: "已暂停。可查看图像或调整最后接缝。")
            : L10n.text(en: "Scroll slowly downward or to the right. Keep at least 25% overlap; stop moving briefly between steps.", zh: "请缓慢向下或向右滚动，保留至少 25% 重叠，每次滚动后稍作停顿。")
    }
    func applyBands() {
        guard segmentCount == 1 else { return }
        performEdit { worker in try await worker.setBands(.init(leading: self.leadingBand, trailing: self.trailingBand)) }
    }
    func adjustSeam() { performEdit { worker in try await worker.adjust(addedPixels: self.seamPixels) } }
    func discardLast() { performEdit { worker in try await worker.discardLast() } }

    private func performEdit(_ operation: @escaping @MainActor (ScrollingCaptureWorker) async throws -> ScrollingCaptureProgress) {
        guard let worker, !isBusy, let id = requestID else { return }
        isPaused = true; isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.isBusy = false } }
            do {
                let progress = try await operation(worker)
                guard self.requestID == id else { return }
                self.update(progress)
                self.message = L10n.text(en: "Correction applied. Review the preview, return to the last accepted position, and resume.", zh: "已应用纠正。请检查预览、返回最后已接收位置，再继续。")
            } catch {
                guard self.requestID == id else { return }
                self.message = error.localizedDescription
            }
        }
    }

    private func run(id: UUID, direction: ScrollingCaptureDirection) async throws -> ScrollingCaptureImage {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureLabError.captureFailed(L10n.text(en: "Allow CaptureLab in System Settings → Privacy & Security → Screen Recording, then try again.", zh: "请在系统设置 → 隐私与安全 → 屏幕录制中允许 CaptureLab，然后重试。"))
        }
        let displays = CaptureDisplay.current()
        var selectionFrames: [String: CGImage] = [:]
        for display in displays {
            guard let uuid = CFUUIDCreateFromString(nil, display.id as CFString),
                  let image = CGDisplayCreateImage(CGDisplayGetDisplayIDFromUUID(uuid)) else {
                throw ScrollingCaptureIssue.invalidFrame
            }
            selectionFrames[display.id] = image
        }
        let region = try await selector.select(displays: displays, frames: selectionFrames, frozen: false)
        selectionFrames.removeAll()
        try Task.checkCancellation()
        guard displays == CaptureDisplay.current(), displays.filter({ $0.frame.intersects(region) }).count == 1,
              let size = PreciseCaptureGeometry.outputSize(region, displays: displays), size.width >= 96,
              size.height >= 96, size.width * size.height <= 12_000_000 else {
            throw CaptureLabError.captureFailed(L10n.text(en: "Select a region inside one display, at least 96 × 96 pixels and up to 12 MP.", zh: "请在单个显示器内选择至少 96 × 96 像素、最多 1200 万像素的区域。"))
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        let quartz = Self.quartzRect(region)
        guard let target = ScrollingCaptureWindow.find(containing: quartz) else {
            throw CaptureLabError.captureFailed(L10n.text(en: "Select the scrolling content fully inside one application window.", zh: "请在同一个应用窗口内完整框选滚动内容。"))
        }
        let worker = ScrollingCaptureWorker()
        self.worker = worker
        let first = try Self.snapshot(region: quartz)
        update(try await worker.begin(image: first, direction: direction))
        showPanel(region: region)
        // Return focus to the target. Our nonactivating panel remains clickable without stealing scroll events.
        NSRunningApplication(processIdentifier: target.ownerPID)?.activate(options: [.activateIgnoringOtherApps])
        let started = ProcessInfo.processInfo.systemUptime
        do {
            while !finishRequested {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 700_000_000)
                guard requestID == id else { throw CancellationError() }
                guard !finishRequested else { break }
                if !isStopped {
                    if CaptureDisplay.current() != displays {
                        stop(L10n.text(en: "Display configuration changed. Finish the accepted image or cancel and select again.", zh: "显示器配置已变化。请结束并保留已接收图像，或取消后重新框选。"))
                    } else if !target.isUnchangedAndVisible(in: quartz) {
                        stop(L10n.text(en: "The selected window moved, resized, closed, or was covered. Finish the accepted image or cancel and select again.", zh: "选定窗口已移动、调整大小、关闭或被遮挡。请结束并保留已接收图像，或取消后重新框选。"))
                    } else if ProcessInfo.processInfo.systemUptime - started > 600 {
                        stop(L10n.text(en: "The 10-minute session limit was reached. Finish the accepted image or cancel.", zh: "已达到 10 分钟会话上限。请结束并保留已接收图像，或取消。"))
                    }
                }
                guard !isPaused, !isStopped, !isBusy else { continue }
                isBusy = true
                do {
                    let image = try Self.snapshot(region: quartz)
                    guard CaptureDisplay.current() == displays, target.isUnchangedAndVisible(in: quartz) else {
                        stop(L10n.text(en: "The window or display changed during capture. Finish the accepted image or cancel.", zh: "捕获时窗口或显示器发生变化。请结束并保留已接收图像，或取消。"))
                        isBusy = false
                        continue
                    }
                    let (result, progress) = try await worker.append(image: image)
                    try Task.checkCancellation()
                    guard requestID == id else { throw CancellationError() }
                    if let progress { update(progress) }
                    switch result {
                    case .duplicate: break
                    case .accepted:
                        message = L10n.text(en: "Segment added. Continue scrolling slowly, or finish.", zh: "已添加一段。可继续缓慢滚动，或点击结束。")
                    case .rejected(let issue):
                        isPaused = true; message = issue.localizedDescription
                        if issue == .dimensionsChanged { isStopped = true }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    isPaused = true; message = error.localizedDescription
                    if !(error is ScrollingCaptureIssue) { isStopped = true }
                }
                isBusy = false
            }
            isBusy = true
            let result = try await worker.finish()
            try Task.checkCancellation()
            await worker.clear()
            return result
        } catch {
            await worker.clear()
            throw error
        }
    }

    private func stop(_ value: String) { isPaused = true; isStopped = true; message = value }
    private func update(_ progress: ScrollingCaptureProgress) {
        preview = NSImage(cgImage: progress.preview.image, size: .zero)
        pendingPreview = progress.pendingPreview.map { NSImage(cgImage: $0.image, size: .zero) }
        dimensions = "\(Int(progress.size.width)) × \(Int(progress.size.height)) px"
        segmentCount = progress.segmentCount
        maximumSeamPixels = progress.maximumAddedPixels
        seamPixels = progress.lastAddedPixels > 0 ? progress.lastAddedPixels : max(1, progress.maximumAddedPixels / 3)
    }

    private func showPanel(region: CGRect) {
        let outline = NSPanel(contentRect: region.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.backgroundColor = .clear
        outline.isOpaque = false
        outline.hasShadow = false
        outline.ignoresMouseEvents = true
        outline.level = .floating
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        outline.isReleasedWhenClosed = false
        outline.hidesOnDeactivate = false
        outline.contentView = ScrollingCaptureOutlineView()
        self.outline = outline
        outline.orderFrontRegardless()
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? region
        let size = CGSize(width: 380, height: min(660, visible.height - 32))
        let x = region.maxX + size.width + 16 <= visible.maxX ? region.maxX + 12 : max(visible.minX + 12, region.minX - size.width - 12)
        let frame = CGRect(x: x, y: min(max(visible.minY + 12, region.maxY - size.height), visible.maxY - size.height - 12), width: size.width, height: size.height)
        let panel = ScrollingCapturePanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = direction.title
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.cancelAction = { [weak self] in self?.cancel() }
        panel.contentView = NSHostingView(rootView: ScrollingCaptureView(controller: self))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    static func quartzRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func snapshot(region: CGRect) throws -> ScrollingCaptureImage {
        guard CGPreflightScreenCaptureAccess(),
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw CaptureLabError.captureFailed(L10n.text(en: "Screen capture permission is no longer available.", zh: "屏幕录制权限已不可用。"))
        }
        // Explicitly exclude every CaptureLab window: the movable control panel may overlap the region.
        let ids = windows.compactMap { entry -> NSNumber? in
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value != ProcessInfo.processInfo.processIdentifier else { return nil }
            return entry[kCGWindowNumber as String] as? NSNumber
        }
        guard let image = CGImage(windowListFromArrayScreenBounds: region, windowArray: ids as CFArray, imageOption: [.bestResolution]) else {
            throw CaptureLabError.captureFailed(L10n.noCaptureFileCreated)
        }
        return ScrollingCaptureImage(image: image)
    }
}

private final class ScrollingCapturePanel: NSPanel {
    var cancelAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { cancelAction?() }
}

private final class ScrollingCaptureOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}

struct ScrollingCaptureWindow: Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect

    static func find(containing rect: CGRect) -> Self? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return find(containing: rect, windows: windows, excludingPID: ProcessInfo.processInfo.processIdentifier)
    }

    static func find(containing rect: CGRect, windows: [[String: Any]], excludingPID: pid_t) -> Self? {
        for entry in windows {
            guard let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.int32Value != excludingPID,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue >= 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.intersects(rect) else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0.01 { continue }
            guard layer.intValue == 0, bounds.contains(rect) else { return nil }
            return Self(id: number.uint32Value, ownerPID: pid.int32Value, bounds: bounds)
        }
        return nil
    }

    func isUnchangedAndVisible(in rect: CGRect) -> Bool { Self.find(containing: rect) == self }
}
