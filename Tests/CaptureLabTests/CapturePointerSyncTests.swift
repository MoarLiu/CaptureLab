import AppKit
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CapturePointerSyncTests: XCTestCase {
    func testSelectionRefreshPreservesMovePreviewAndCommitsItOnMouseUp() throws {
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        let harness = try PointerSyncHarness(annotation: annotation)
        defer { harness.close() }

        harness.pointer(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        harness.pointer(.leftMouseDragged, at: CGPoint(x: 290, y: 230))
        let preview = try XCTUnwrap(harness.canvas.annotations.first)
        XCTAssertNotEqual(preview, annotation)
        XCTAssertEqual(harness.state.annotations, [annotation], "Pointer previews are committed only on release.")

        // Selecting the annotation publishes through SwiftUI while its native
        // drag preview still has newer geometry than the model binding.
        harness.drainUI()

        XCTAssertEqual(harness.state.selection, annotation.id)
        XCTAssertEqual(harness.state.canvasSelectionChanges, [annotation.id])
        XCTAssertEqual(harness.canvas.annotations, [preview])
        harness.pointer(.leftMouseUp, at: CGPoint(x: 290, y: 230))
        harness.drainUI()
        XCTAssertEqual(harness.state.annotations, [preview])
        XCTAssertFalse(harness.canvas.hasActivePointerInteraction)
    }

    func testSwiftUIRefreshPreservesResizePreviewUntilMouseUp() throws {
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        let harness = try PointerSyncHarness(annotation: annotation, selected: true)
        defer { harness.close() }

        harness.pointer(.leftMouseDown, at: CGPoint(x: 360, y: 260))
        harness.pointer(.leftMouseDragged, at: CGPoint(x: 420, y: 300))
        let preview = try XCTUnwrap(harness.canvas.annotations.first)
        XCTAssertGreaterThan(preview.normalizedRect.width, annotation.normalizedRect.width)
        harness.state.appearance.lineWidth = 7
        harness.drainUI()

        XCTAssertEqual(harness.canvas.annotations, [preview])
        XCTAssertEqual(harness.state.annotations, [annotation])
        harness.pointer(.leftMouseUp, at: CGPoint(x: 420, y: 300))
        harness.drainUI()
        XCTAssertEqual(harness.state.annotations, [preview])
    }

    func testSwiftUIRefreshPreservesArrowEndpointPreviewUntilMouseUp() throws {
        let annotation = CaptureAnnotation.arrow(start: CGPoint(x: 0.125, y: 0.125), end: CGPoint(x: 0.4375, y: 0.4167))
        let harness = try PointerSyncHarness(annotation: annotation, selected: true)
        defer { harness.close() }

        harness.pointer(.leftMouseDown, at: CGPoint(x: 360, y: 260))
        harness.pointer(.leftMouseDragged, at: CGPoint(x: 440, y: 320))
        let preview = try XCTUnwrap(harness.canvas.annotations.first)
        XCTAssertGreaterThan(preview.normalizedPoints[1].x, annotation.normalizedPoints[1].x)
        harness.state.appearance.lineWidth = 7
        harness.drainUI()

        XCTAssertEqual(harness.canvas.annotations, [preview])
        harness.pointer(.leftMouseUp, at: CGPoint(x: 440, y: 320))
        harness.drainUI()
        XCTAssertEqual(harness.state.annotations, [preview])
    }

    func testDocumentReplacementCancelsPointerEditAndSynchronizesNewAnnotations() throws {
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        let harness = try PointerSyncHarness(annotation: annotation)
        defer { harness.close() }
        harness.pointer(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        harness.pointer(.leftMouseDragged, at: CGPoint(x: 290, y: 230))
        XCTAssertTrue(harness.canvas.hasActivePointerInteraction)

        harness.state.document.id = UUID()
        harness.state.annotations = []
        harness.state.selection = nil
        harness.drainUI()

        XCTAssertEqual(harness.state.canvasSelectionChanges, [annotation.id], "Model replacement must not publish a native selection reset.")
        XCTAssertFalse(harness.canvas.hasActivePointerInteraction)
        XCTAssertTrue(harness.canvas.annotations.isEmpty)
        harness.pointer(.leftMouseUp, at: CGPoint(x: 290, y: 230))
        XCTAssertTrue(harness.state.annotations.isEmpty)
    }

    func testClearDuringDragCancelsPointerEditAndMouseUpDoesNotRestoreDeletedAnnotations() throws {
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        let harness = try PointerSyncHarness(annotation: annotation)
        defer { harness.close() }
        harness.pointer(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        harness.pointer(.leftMouseDragged, at: CGPoint(x: 290, y: 230))
        XCTAssertTrue(harness.canvas.hasActivePointerInteraction)

        // Clear/undo commands change the model without changing the document,
        // tool, or zoom. That edit must take precedence over the older gesture.
        harness.state.annotations = []
        harness.drainUI()

        XCTAssertEqual(harness.state.canvasSelectionChanges, [annotation.id], "Model clearing must not publish a native selection reset.")
        XCTAssertFalse(harness.canvas.hasActivePointerInteraction)
        XCTAssertTrue(harness.canvas.annotations.isEmpty)
        harness.pointer(.leftMouseUp, at: CGPoint(x: 290, y: 230))
        harness.drainUI()
        XCTAssertTrue(harness.state.annotations.isEmpty)
    }

    func testUndoDuringDragCancelsPointerEditAndMouseUpPreservesRestoredGeometry() throws {
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        let restored = annotation.withNormalizedRect(CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2))
        let harness = try PointerSyncHarness(annotation: annotation)
        defer { harness.close() }
        harness.pointer(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        harness.pointer(.leftMouseDragged, at: CGPoint(x: 290, y: 230))

        harness.state.annotations = [restored]
        harness.state.selection = nil
        harness.drainUI()

        XCTAssertEqual(harness.state.canvasSelectionChanges, [annotation.id], "Undo selection synchronization must not publish back to the model.")
        XCTAssertFalse(harness.canvas.hasActivePointerInteraction)
        XCTAssertEqual(harness.canvas.annotations, [restored])
        harness.pointer(.leftMouseUp, at: CGPoint(x: 290, y: 230))
        harness.drainUI()
        XCTAssertEqual(harness.state.annotations, [restored])
    }

    func testToolAndZoomChangesCancelPointerEditAndRestoreCommittedGeometry() throws {
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        for changesZoom in [false, true] {
            let harness = try PointerSyncHarness(annotation: annotation)
            defer { harness.close() }
            harness.pointer(.leftMouseDown, at: CGPoint(x: 250, y: 200))
            harness.pointer(.leftMouseDragged, at: CGPoint(x: 290, y: 230))
            XCTAssertTrue(harness.canvas.hasActivePointerInteraction)

            if changesZoom {
                harness.state.zoom = .actual
            } else {
                harness.state.tool = .arrow
            }
            harness.drainUI()

            XCTAssertEqual(harness.state.canvasSelectionChanges, [annotation.id], "Tool and zoom synchronization must not publish back to the model.")
            XCTAssertFalse(harness.canvas.hasActivePointerInteraction)
            XCTAssertEqual(harness.canvas.annotations, [annotation])
            harness.pointer(.leftMouseUp, at: CGPoint(x: 290, y: 230))
            XCTAssertEqual(harness.state.annotations, [annotation])
        }
    }
}

@MainActor
private final class PointerSyncHarness {
    let state: PointerSyncState
    let canvas: CaptureAnnotationNSCanvasView
    private let window: NSWindow
    private let hosting: NSHostingView<PointerSyncRootView>

    init(annotation: CaptureAnnotation, selected: Bool = false) throws {
        _ = NSApplication.shared
        let state = try PointerSyncState(annotation: annotation, selected: selected)
        let hosting = NSHostingView(rootView: PointerSyncRootView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        CaptureLabAppDelegate.allowNextMainWindowPresentation()
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        Self.flushUpdates()
        let canvas = try XCTUnwrap(Self.descendants(of: hosting).compactMap { $0 as? CaptureAnnotationNSCanvasView }.first)
        self.state = state
        self.hosting = hosting
        self.window = window
        self.canvas = canvas
        XCTAssertEqual(canvas.bounds.size, CGSize(width: 800, height: 600))
    }

    func pointer(_ type: NSEvent.EventType, at point: CGPoint) {
        let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: XCTFail("Unexpected pointer event")
        }
    }

    func drainUI() {
        Self.flushUpdates()
        hosting.layoutSubtreeIfNeeded()
    }

    func close() {
        canvas.prepareForDismantle()
        window.close()
    }

    private static func flushUpdates() {
        for _ in 0..<4 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class PointerSyncState: ObservableObject {
    @Published var document: CaptureDocument
    @Published var annotations: [CaptureAnnotation] {
        didSet {
            if let selection, !annotations.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }
    @Published var tool = CaptureTool.select {
        didSet {
            if let selected = annotations.first(where: { $0.id == selection }),
               tool != .select, tool.annotationKind != selected.kind {
                selection = nil
            }
        }
    }
    @Published var zoom = CaptureZoomLevel.fit
    @Published var selection: UUID?
    @Published var appearance = CaptureAnnotationAppearance.editorDefault
    var canvasSelectionChanges: [UUID?] = []
    let editingSession = CaptureEditingSession()

    init(annotation: CaptureAnnotation, selected: Bool) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 400, height: 300))
        document = CaptureDocument(image: image, sourceURL: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        annotations = [annotation]
        selection = selected ? annotation.id : nil
    }

    func acceptCanvasSelection(_ id: UUID?) {
        canvasSelectionChanges.append(id)
        if selection != id { selection = id }
    }
}

@MainActor
private struct PointerSyncRootView: View {
    @ObservedObject var state: PointerSyncState

    var body: some View {
        CaptureAnnotationCanvasView(document: state.document, annotations: $state.annotations,
            selectedTool: $state.tool, zoomLevel: $state.zoom,
            editingSession: state.editingSession, annotationAppearance: state.appearance,
            selectedAnnotationID: state.selection, onSelectionChanged: { state.acceptCanvasSelection($0) })
    }
}
