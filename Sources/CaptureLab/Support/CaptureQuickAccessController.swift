import AppKit
import SwiftUI

@MainActor
final class CaptureQuickAccessController: NSObject, ObservableObject, NSWindowDelegate {
    struct Entry: Identifiable {
        let snapshot: CaptureImageSnapshot
        let screenNumber: NSNumber?
        let edit: () -> Bool
        let copy: () -> Void
        let save: () -> Void
        let pin: () -> Void
        let upload: () -> Void
        var id: UUID { snapshot.id }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isTemporarilyHidden = false
    @Published private(set) var lastClosed: Entry?
    private(set) var window: NSPanel?
    var isCapturing = false {
        didSet {
            if isCapturing {
                window?.orderOut(nil)
                scheduleDismissal()
            } else if !isTemporarilyHidden, !entries.isEmpty {
                present()
            }
        }
    }
    var isDragging = false { didSet { scheduleDismissal() } }
    var isHovering = false { didSet { scheduleDismissal() } }
    private var timeout: Task<Void, Never>?
    private var options = CaptureWorkflowOptions()
    private var screenObserver: Any?

    var selected: Entry? { entries.first { $0.id == selectedID } ?? entries.first }

    func show(_ entry: Entry, options: CaptureWorkflowOptions) {
        self.options = options.validated
        entries.insert(entry, at: 0)
        // Closed entries remain in history. Bound both metadata and pixel memory.
        while entries.count > 30 || (entries.count > 1 && entries.reduce(0, { $0 + $1.snapshot.data.count }) > 128 * 1_024 * 1_024) {
            entries.removeLast()
        }
        selectedID = entry.id
        isTemporarilyHidden = false
        present()
    }

    func select(_ id: UUID) {
        selectedID = id
        positionWindow()
        scheduleDismissal()
    }

    func dismissSelected() {
        guard let selected else { return }
        lastClosed = selected
        entries.removeAll { $0.id == selected.id }
        selectedID = entries.first?.id
        if entries.isEmpty { window?.orderOut(nil) }
        else { positionWindow() }
        scheduleDismissal()
    }

    func restoreLast() {
        guard let entry = lastClosed else { return }
        lastClosed = nil
        show(entry, options: options)
    }

    func toggleHidden() {
        isTemporarilyHidden.toggle()
        if isTemporarilyHidden { window?.orderOut(nil) }
        else if !entries.isEmpty { present() }
        scheduleDismissal()
    }

    func updateOptions(_ options: CaptureWorkflowOptions) {
        self.options = options.validated
        positionWindow()
        scheduleDismissal()
    }

    private func present() {
        guard !isCapturing, !isTemporarilyHidden, !entries.isEmpty else { return }
        if window == nil {
            let panel = CaptureQuickAccessPanel(contentRect: .zero,
                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = L10n.overlayTitle
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            panel.onEscape = { [weak self] in self?.dismissSelected() }
            panel.contentView = NSHostingView(rootView: CaptureQuickAccessView(controller: self))
            window = panel
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.positionWindow() }
                }
        }
        positionWindow()
        window?.orderFrontRegardless()
        scheduleDismissal()
    }

    private func positionWindow() {
        guard let window else { return }
        let screen = options.followsCaptureScreen
            ? NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == selected?.screenNumber }
            : NSScreen.screens.first
        guard let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = CGSize(width: min(CGFloat(options.overlayWidth), visible.width), height: min(300, visible.height))
        let content = NSRect(origin: .zero, size: size)
        let frameSize = window.frameRect(forContentRect: content).size
        window.setFrame(Self.frame(size: frameSize, visibleFrame: visible, corner: options.corner), display: true)
    }

    static func frame(size: CGSize, visibleFrame: CGRect, corner: CaptureOverlayCorner) -> CGRect {
        let padding: CGFloat = 16
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let left = corner == .bottomLeft || corner == .topLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: max(visibleFrame.minX, min(visibleFrame.maxX - width,
                          left ? visibleFrame.minX + padding : visibleFrame.maxX - width - padding)),
                      y: max(visibleFrame.minY, min(visibleFrame.maxY - height,
                          top ? visibleFrame.maxY - height - padding : visibleFrame.minY + padding)),
                      width: width, height: height)
    }

    private func scheduleDismissal() {
        timeout?.cancel()
        timeout = nil
        guard options.autoCloseSeconds > 0, !isCapturing, !isDragging, !isHovering,
              !isTemporarilyHidden, let id = selected?.id, window?.isVisible == true else { return }
        let seconds = options.autoCloseSeconds
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, self.selected?.id == id else { return }
            self.dismissSelected()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissSelected()
        return false
    }

    func tearDown() {
        timeout?.cancel()
        timeout = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
        window = nil
        entries = []
        selectedID = nil
        lastClosed = nil
        isHovering = false
        isDragging = false
    }
}

private final class CaptureQuickAccessPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

private struct CaptureQuickAccessView: View {
    @ObservedObject var controller: CaptureQuickAccessController
    var body: some View {
        VStack(spacing: 10) {
            if let entry = controller.selected {
                HStack {
                    Text(L10n.overlayTitle).font(.headline)
                    Spacer()
                    Text("\(controller.entries.firstIndex(where: { $0.id == entry.id }).map { $0 + 1 } ?? 1) / \(controller.entries.count)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                if let image = entry.snapshot.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 12) {
                    action("doc.on.doc", L10n.copyEditedImage, entry.copy)
                    action("square.and.arrow.down", L10n.saveEditedImage, entry.save)
                    action("pencil", L10n.openRecentCapture) {
                        if entry.edit() { controller.dismissSelected() }
                    }
                    action("pin", L10n.pinImage, entry.pin)
                    action("icloud.and.arrow.up", L10n.uploadEditedImage, entry.upload)
                    CaptureImageDragSource(snapshot: { entry.snapshot }, onDragging: { controller.isDragging = $0 })
                        .frame(width: 28, height: 28)
                    action("xmark", L10n.pinClose, controller.dismissSelected)
                }
                if controller.entries.count > 1 {
                    HStack {
                        ForEach([-1, 1], id: \.self) { delta in
                            Button {
                                let index = controller.entries.firstIndex { $0.id == entry.id } ?? 0
                                let next = (index + delta + controller.entries.count) % controller.entries.count
                                controller.select(controller.entries[next].id)
                            } label: {
                                Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                            }
                            .accessibilityLabel(delta < 0 ? L10n.text(en: "Newer capture", zh: "较新截图") : L10n.text(en: "Older capture", zh: "较早截图"))
                        }
                        Spacer()
                        Button(L10n.overlayHide, action: controller.toggleHidden).font(.caption)
                    }
                }
            }
        }
        .padding(14).padding(.top, 20)
        .background(Color(nsColor: .windowBackgroundColor))
        .onHover { controller.isHovering = $0 }
    }
    private func action(_ symbol: String, _ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(width: 16, height: 20) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
