import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureObjectPreviewTests: XCTestCase {
    func testObjectDragPreviewPreservesPendingGeometryAndMeasuresCompositionWork() throws {
        _ = NSApplication.shared
        let large = ProcessInfo.processInfo.environment["CAPTURELAB_OBJECT_BENCHMARK"] == "1"
        let source = try image(width: large ? 3840 : 320, height: large ? 2160 : 180)
        let png = try XCTUnwrap(image(width: large ? 1920 : 160, height: large ? 1080 : 90).captureLabPNGData())
        var document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
        document.imageLayers = (0..<4).map { index in
            CaptureImageLayer(name: "Synthetic-\(index).png", pngData: png,
                normalizedRect: CGRect(x: 0.1 + CGFloat(index) * 0.02, y: 0.1, width: 0.5, height: 0.5), zIndex: index)
        }
        let canvas = CaptureLayersNSCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.synchronize(document: document, annotations: [], selection: [.image(document.imageLayers[3].id)], zoom: .fit)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        func paint() { canvas.cacheDisplay(in: canvas.bounds, to: bitmap) }
        paint()
        let rect = canvas.outputDisplayRect
        let start = CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.35)
        func pointer(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        try pointer(.leftMouseDown, start)
        let before = canvas.compositionRenderCount
        let started = Date()
        for index in 0..<100 {
            try pointer(.leftMouseDragged, CGPoint(x: start.x + CGFloat(index % 20), y: start.y + 5))
            if large || index == 99 { paint() }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotEqual(canvas.layers, document.imageLayers)
        XCTAssertEqual(canvas.layers.map(\.zIndex), document.imageLayers.map(\.zIndex))
        XCTAssertEqual(canvas.compositionRenderCount - before, large ? 100 : 1)
        XCTAssertEqual(canvas.previewDecodeCount, 4, "Moving immutable resources must reuse decoded images")
        if large {
            XCTAssertLessThan(try XCTUnwrap(canvas.previewPixelSize).width, document.sourcePixelSize.width)
            print("OBJECT_PREVIEW_BENCHMARK frames=100 seconds=\(elapsed) pixels=\(String(describing: canvas.previewPixelSize))")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureHistoryBenchmark-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = CaptureHistoryStore(environment: ["HOME": root.path])
            let bytes = Data(repeating: 0x5a, count: 64 * 1_024 * 1_024)
            _ = try history.saveEditable(preview: png, project: bytes, for: nil,
                pixelSize: document.pixelSize, createdAt: document.createdAt)
            #if DEBUG
            print("HISTORY_LOCK_BENCHMARK synthetic_project_bytes=\(bytes.count) seconds=\(history.lastLockDuration)")
            #endif
        }
        canvas.onCommit = { _, _ in false }
        try pointer(.leftMouseUp, start)
        XCTAssertEqual(canvas.layers, document.imageLayers, "Rejected commits restore the original preview")
        paint()
        XCTAssertEqual(canvas.previewPixelSize, document.sourcePixelSize, "Mouse release restores the exact preview")
    }

    func testPreviewKeepsImageStackingAndInvalidatesReplacedResourceWithSameID() throws {
        let source = try solid(.white)
        let red = CaptureImageLayer(name: "red", pngData: try XCTUnwrap(solid(.red).captureLabPNGData()),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), zIndex: 0)
        let blue = CaptureImageLayer(name: "blue", pngData: try XCTUnwrap(solid(.blue).captureLabPNGData()),
            normalizedRect: CGRect(x: 0.4, y: 0.2, width: 0.5, height: 0.6), zIndex: 1)
        let document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
        let renderer = CaptureCompositionPreviewRenderer()
        let first = try XCTUnwrap(renderer.render(document: document, layers: [red, blue], annotations: [], maximumDimension: 1024))
        XCTAssertEqual(try pixels(first), try pixels(XCTUnwrap(CaptureLayerComposition.render(source: source, layers: [red, blue]))))
        var moved = red
        moved.normalizedRect.origin.x += 0.05
        let second = try XCTUnwrap(renderer.render(document: document, layers: [moved, blue], annotations: [], maximumDimension: 1024))
        XCTAssertEqual(try pixels(second), try pixels(XCTUnwrap(CaptureLayerComposition.render(source: source, layers: [moved, blue]))))
        XCTAssertEqual(renderer.decodeCount, 2)
        let replaced = CaptureImageLayer(id: red.id, name: red.name, pngData: try XCTUnwrap(solid(.green).captureLabPNGData()),
            normalizedRect: moved.normalizedRect, zIndex: red.zIndex)
        let third = try XCTUnwrap(renderer.render(document: document, layers: [replaced, blue], annotations: [], maximumDimension: 1024))
        XCTAssertEqual(renderer.decodeCount, 3)
        XCTAssertNotEqual(try pixels(second), try pixels(third))
        let broken = CaptureImageLayer(id: red.id, name: red.name, pngData: Data([1]), normalizedRect: red.normalizedRect)
        XCTAssertNil(renderer.render(document: document, layers: [broken, blue], annotations: [], maximumDimension: 1024))
    }

    func testNativeScalePreviewMatchesExactRedactionsGeometryAndPresentation() throws {
        let source = try image(width: 192, height: 120)
        var document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
        let layer = CaptureImageLayer(name: "layer", pngData: try XCTUnwrap(solid(.red).captureLabPNGData()),
            normalizedRect: CGRect(x: 0.15, y: 0.15, width: 0.3, height: 0.4), rotationDegrees: 23)
        document.imageLayers = [layer]
        let annotations: [CaptureAnnotation] = [
            .init(kind: .mosaic, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)),
            .init(kind: .blur, normalizedRect: CGRect(x: 0.3, y: 0.2, width: 0.5, height: 0.5), appearance: .init(blurRadius: 12))
        ]
        document = try XCTUnwrap(document.cropping(to: CGRect(x: 0.125, y: 0.1, width: 0.75, height: 0.8)))
        document = document.adjusting(.rotateClockwise).adjusting(.flipHorizontal)
        document.presentation.padding = 8
        document.presentation.cornerRadius = 6
        document.presentation.background = .gradient
        let layers = try XCTUnwrap(CaptureLayerComposition.render(source: source, layers: [layer]))
        let annotated = try XCTUnwrap(layers.renderedWithCaptureLabAnnotations(annotations))
        let exact = try XCTUnwrap(document.presentation.render(XCTUnwrap(document.applyingGeometry(to: annotated))))
        let renderer = CaptureCompositionPreviewRenderer()
        let preview = try XCTUnwrap(renderer.render(document: document, layers: [layer], annotations: annotations,
            maximumDimension: 1024, includesPresentation: true))
        XCTAssertEqual(try pixels(preview), try pixels(exact))
    }

    func testPreviewBudgetAndMosaicScaleRemainBounded() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 192, height: 96, bitsPerComponent: 8,
            bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<32 {
            context.setFillColor(CGColor(gray: index % 2 == 0 ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: index * 6, y: 0, width: 6, height: 96))
        }
        let source = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 192, height: 96))
        let document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
        let renderer = CaptureCompositionPreviewRenderer(cacheByteLimit: 16_384)
        let annotation = CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let preview = try XCTUnwrap(renderer.render(document: document, layers: [], annotations: [annotation], maximumDimension: 96))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(preview.captureLabCGImage()))
        // Original six-pixel blocks become three-pixel blocks, rather than
        // retaining six preview pixels and merging neighboring colors.
        for index in 0..<10 {
            let color = try XCTUnwrap(bitmap.colorAt(x: index * 3 + 1, y: 20)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, index % 2 == 0 ? 0 : 1, accuracy: 0.1)
        }
        let data = try XCTUnwrap(solid(.red).captureLabPNGData())
        let layers = (0..<8).map { _ in CaptureImageLayer(name: "layer", pngData: data,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)) }
        XCTAssertNotNil(renderer.render(document: document, layers: layers, annotations: [], maximumDimension: 1024))
        XCTAssertLessThanOrEqual(renderer.cachedBytes, 16_384)
    }

    private func solid(_ color: NSColor) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 64, height: 48))
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let cg = try XCTUnwrap(image.captureLabCGImage())
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
    }

    private func image(width: Int, height: Int) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0.2, blue: 0.8, alpha: 1))
        for x in stride(from: 0, to: width, by: 24) {
            context.fill(CGRect(x: x, y: 0, width: 12, height: height))
        }
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
    }
}
