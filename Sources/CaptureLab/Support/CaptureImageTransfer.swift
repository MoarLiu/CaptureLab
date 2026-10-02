import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Immutable pixels for a specific action; never consults the active document later.
struct CaptureImageSnapshot: Identifiable, Sendable {
    let id: UUID
    let data: Data
    let fileName: String
    let historyItem: CaptureHistoryItem?

    @MainActor
    var image: NSImage? { NSImage(data: data) }

    init(data: Data, fileName: String = "CaptureLab.png", historyItem: CaptureHistoryItem? = nil) {
        self.id = UUID()
        self.data = data
        self.fileName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent + ".png"
        self.historyItem = historyItem
    }
}

enum CaptureImageImport {
    static let maximumBytes = 128 * 1_024 * 1_024
    static let maximumPixels = 100_000_000

    @MainActor
    static func pngData(from data: Data) throws -> Data {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height,
              let image = NSImage(data: data), image.isValid,
              let png = image.captureLabPNGData() else {
            throw CaptureLabError.imageLoadFailed
        }
        return png
    }

    @MainActor
    static func data(from url: URL) throws -> Data {
        guard url.isFileURL,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { throw CaptureLabError.imageLoadFailed }
        return try pngData(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    @MainActor
    static func data(from pasteboard: NSPasteboard) throws -> Data {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return try pngData(from: data) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first { return try data(from: url) }
        throw CaptureLabError.imageLoadFailed
    }
}

/// The destination owns the promised file. No temporary export is deleted while
/// another app is still receiving it, and no unredacted source URL is exposed.
final class CapturePNGPromise: NSObject, NSFilePromiseProviderDelegate {
    let snapshot: CaptureImageSnapshot
    init(snapshot: CaptureImageSnapshot) { self.snapshot = snapshot }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        snapshot.fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try snapshot.data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

final class CapturePNGPromiseProvider: NSFilePromiseProvider {
    // NSFilePromiseProvider's delegate is weak. Keep the immutable payload alive
    // even if the source window closes before the receiver asks for the file.
    private let retainedDelegate: CapturePNGPromise

    init(snapshot: CaptureImageSnapshot) {
        retainedDelegate = CapturePNGPromise(snapshot: snapshot)
        super.init()
        fileType = UTType.png.identifier
        delegate = retainedDelegate
    }
    required init?(coder: NSCoder) { nil }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .png { return retainedDelegate.snapshot.data }
        return super.pasteboardPropertyList(forType: type)
    }
}

struct CaptureImageDragSource: NSViewRepresentable {
    let snapshot: @MainActor () -> CaptureImageSnapshot?
    var isEnabled = true
    var onDragging: @MainActor (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> CaptureImageDragView { CaptureImageDragView() }
    func updateNSView(_ view: CaptureImageDragView, context: Context) {
        view.snapshot = snapshot
        view.onDragging = onDragging
        view.isEnabled = isEnabled
        view.alphaValue = isEnabled ? 1 : 0.35
    }
}

@MainActor
final class CaptureImageDragView: NSView, NSDraggingSource {
    var snapshot: (() -> CaptureImageSnapshot?)?
    var onDragging: (Bool) -> Void = { _ in }
    var isEnabled = true
    private var mouseOrigin: NSPoint?
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = L10n.dragImage
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.dragImage)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "hand.draw", accessibilityDescription: L10n.dragImage)?
            .draw(in: bounds.insetBy(dx: 5, dy: 5))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { mouseOrigin = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let origin = mouseOrigin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 3,
              let snapshot = snapshot?(), let image = snapshot.image else { return }
        mouseOrigin = nil
        let item = NSDraggingItem(pasteboardWriter: CapturePNGPromiseProvider(snapshot: snapshot))
        item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil),
                                    size: NSSize(width: 96, height: 72)), contents: image)
        onDragging(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragging(false) }
}

/// Cmd-V is intercepted only outside a text responder, preserving normal text editing.
struct CaptureImagePasteInstaller: NSViewRepresentable {
    let paste: @MainActor () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.attach(view, paste: paste) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var paste: (() -> Void)?
        var monitor: Any?
        func attach(_ view: NSView, paste: @escaping () -> Void) {
            self.view = view
            self.paste = paste
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.view?.window, event.window === window,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers?.lowercased() == "v",
                          !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField)
                    else { return false }
                    self.paste?()
                    return true
                }
                return consumed ? nil : event
            }
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
